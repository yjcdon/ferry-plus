package platform

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/egoist/mygo"
)

// LocalReference identifies a user-selected local item across launches.
type LocalReference struct {
	Path      string            `json:"path"`
	Bookmark  []byte            `json:"bookmark,omitempty"`
	Directory directoryIdentity `json:"directory,omitzero"`
}

type directoryIdentity struct {
	Inode uint64 `json:"inode"`
	Birth int64  `json:"birth"`
}

// LocalAccess keeps a selected path accessible until Close.
type LocalAccess struct {
	Reference LocalReference
	release   func()
}

func (a *LocalAccess) Close() {
	if a.release != nil {
		a.release()
		a.release = nil
	}
}

type localPickerMode uint8

const (
	pickUploadItems localPickerMode = iota
	pickUploadSource
	pickDownloadFolder
)

// ChooseUploadItems opens one system picker for files and folders. Cancellation
// calls done with no items and no error. The returned function closes the picker.
func ChooseUploadItems(parent *mygo.Window, done func([]LocalReference, error)) func() {
	return chooseLocalItems(parent, pickUploadItems, done)
}

// ChooseUploadSource selects one replacement file for an existing upload.
func ChooseUploadSource(parent *mygo.Window, done func([]LocalReference, error)) func() {
	return chooseLocalItems(parent, pickUploadSource, done)
}

// ChooseDownloadFolder opens the system folder picker. Cancellation calls done
// with a zero reference and no error.
func ChooseDownloadFolder(parent *mygo.Window, done func(LocalReference, error)) func() {
	return chooseLocalItems(parent, pickDownloadFolder, func(items []LocalReference, err error) {
		if len(items) == 0 || err != nil {
			done(LocalReference{}, err)
			return
		}
		done(items[0], nil)
	})
}

// RememberLocalItem records the access granted by a system selection or drop.
func RememberLocalItem(path string) (LocalReference, error) {
	path, err := absoluteLocalPath(path)
	if err != nil {
		return LocalReference{}, err
	}
	return rememberLocalItem(path)
}

// OpenLocalItem restores access and returns the current location and bookmark.
// The caller persists any changes and closes the access when its work ends.
func OpenLocalItem(ref LocalReference) (*LocalAccess, error) {
	path, err := absoluteLocalPath(ref.Path)
	if err != nil {
		return nil, err
	}
	ref.Path = path
	access, err := openLocalItem(ref)
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(access.Reference.Path); err != nil {
		access.Close()
		return nil, err
	}
	return access, nil
}

// RevealLocalItem selects an existing item in Finder or File Explorer.
func RevealLocalItem(path string) error {
	path, err := absoluteLocalPath(path)
	if err != nil {
		return err
	}
	if _, err := os.Lstat(path); err != nil {
		return err
	}
	mygo.Shell.ShowItemInFolder(path)
	return nil
}

// TrashLocalItem moves an item to the system trash and reports any refusal.
func TrashLocalItem(path string) error {
	path, err := absoluteLocalPath(path)
	if err != nil {
		return err
	}
	return mygo.Shell.TrashItem(path)
}

func absoluteLocalPath(path string) (string, error) {
	if !filepath.IsAbs(path) || strings.ContainsRune(path, 0) {
		return "", fmt.Errorf("本地路径无效 %q", path)
	}
	return filepath.Clean(path), nil
}

// DownloadRelativePath converts a remote relative path for use with os.Root.
// Keep all file access under the chosen root so links cannot escape it.
func DownloadRelativePath(remote string) (string, error) {
	if remote == "." || !fs.ValidPath(remote) || strings.HasPrefix(remote, `\`) ||
		strings.ContainsRune(remote, 0) || hasDrivePrefix(remote) {
		return "", fmt.Errorf("下载路径无效 %q", remote)
	}
	if err := validateLocalNames(remote); err != nil {
		return "", err
	}
	path, err := filepath.Localize(remote)
	if err != nil {
		return "", fmt.Errorf("下载路径无法在本机使用 %q: %w", remote, err)
	}
	return path, nil
}

func hasDrivePrefix(path string) bool {
	if len(path) < 2 || path[1] != ':' {
		return false
	}
	letter := path[0] | 0x20
	return letter >= 'a' && letter <= 'z'
}
