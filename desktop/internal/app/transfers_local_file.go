package app

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

type downloadLocalReceipt struct {
	Relative string
	Identity downloadFileIdentity
}

type downloadFileIdentity struct {
	ID       uint64
	Volume   uint32
	Birth    int64
	Modified int64
}

func rememberDownloadFile(folder platform.LocalReference, absolute string, size int64) (downloadLocalReceipt, error) {
	access, err := platform.OpenLocalItem(folder)
	if err != nil {
		return downloadLocalReceipt{}, err
	}
	defer access.Close()
	relative, err := filepath.Rel(access.Reference.Path, absolute)
	if err != nil {
		return downloadLocalReceipt{}, err
	}
	relative, err = platform.DownloadRelativePath(filepath.ToSlash(relative))
	if err != nil {
		return downloadLocalReceipt{}, err
	}
	root, err := os.OpenRoot(access.Reference.Path)
	if err != nil {
		return downloadLocalReceipt{}, err
	}
	defer root.Close()
	identity, _, err := inspectDownloadFile(root, relative, size)
	if err != nil {
		return downloadLocalReceipt{}, err
	}
	if identity.ID == 0 {
		return downloadLocalReceipt{}, nil // This filesystem cannot prove identity on removal.
	}
	return downloadLocalReceipt{Relative: filepath.ToSlash(relative), Identity: identity}, nil
}

// inspectDownloadFile rejects replaced objects, links and directory junctions.
// Keeping the traversal rooted also protects against ancestors escaping the
// selected download directory.
func inspectDownloadFile(root *os.Root, relative string, size int64) (downloadFileIdentity, os.FileInfo, error) {
	components := strings.Split(filepath.ToSlash(relative), "/")
	var name string
	var before os.FileInfo
	for i, component := range components {
		name = filepath.Join(name, component)
		info, err := root.Lstat(name)
		if err != nil {
			return downloadFileIdentity{}, nil, err
		}
		if i < len(components)-1 {
			if !info.IsDir() {
				return downloadFileIdentity{}, nil, errors.New("下载文件的上级目录已变化")
			}
		} else {
			before = info
		}
	}
	if !before.Mode().IsRegular() || before.Size() != size {
		return downloadFileIdentity{}, nil, errors.New("下载文件已变化")
	}
	file, err := root.Open(relative)
	if err != nil {
		return downloadFileIdentity{}, nil, err
	}
	defer file.Close()
	after, err := file.Stat()
	if err != nil {
		return downloadFileIdentity{}, nil, err
	}
	if !os.SameFile(before, after) || after.Size() != size {
		return downloadFileIdentity{}, nil, errors.New("下载文件已变化")
	}
	identity, err := downloadIdentity(file, after)
	return identity, after, err
}

func trashDownloadedFile(root *os.Root, item TransferItem, trash func(string) error) error {
	if item.LocalReceipt.Identity.ID == 0 {
		return errors.New("缺少本地文件身份，请在文件管理器中确认后处理")
	}
	relative, err := platform.DownloadRelativePath(item.LocalReceipt.Relative)
	if err != nil {
		return err
	}
	identity, info, err := inspectDownloadFile(root, relative, item.Size)
	if errors.Is(err, fs.ErrNotExist) {
		return nil // Already moved, including interruption before saving its receipt.
	}
	if err != nil {
		return err
	}
	if identity != item.LocalReceipt.Identity {
		return errors.New("下载文件已变化，已保留现有文件")
	}
	absolute := filepath.Join(root.Name(), relative)
	// A directory can move after os.Root was opened. The absolute path used
	// by the system trash must still name the inspected file.
	actual, err := os.Lstat(absolute)
	if err != nil || !os.SameFile(info, actual) || actual.Size() != info.Size() || !actual.ModTime().Equal(info.ModTime()) {
		return errors.New("下载文件的位置已变化，已保留现有文件")
	}
	if err := trash(absolute); err != nil {
		return err
	}
	if _, err := root.Lstat(relative); !errors.Is(err, fs.ErrNotExist) {
		if err == nil {
			return errors.New("系统回收站未确认移除")
		}
		return fmt.Errorf("确认回收站结果: %w", err)
	}
	return nil
}
