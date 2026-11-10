package core

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"

	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

// RevealUploadSource resolves the current authorized local item without
// changing the source, task status or cloud objects.
func (u *Uploader) RevealUploadSource(id, relative string) error {
	return u.withUploadSourcePath(id, relative, platform.RevealLocalItem)
}

func (u *Uploader) withUploadSourcePath(id, relative string, reveal func(string) error) error {
	manifest, err := u.savedUploadManifest(uploadJobKey(id))
	if err != nil {
		return err
	}
	index := slices.IndexFunc(manifest.Entries, func(entry uploadLocalItem) bool { return entry.Relative == relative })
	if index < 0 {
		return errors.New("找不到上传源文件位置。")
	}
	entry := manifest.Entries[index]
	ref, err := uploadSourceFor(manifest, &entry)
	if err != nil {
		return err
	}
	access, err := platform.OpenLocalItem(ref)
	if err != nil {
		return fmt.Errorf("打开源文件 %s: %w", filepath.Join(ref.Path, entry.Inside), err)
	}
	defer access.Close()
	resolved := access.Reference.Path
	if entry.Inside != "." {
		root, err := os.OpenRoot(resolved)
		if err != nil {
			return err
		}
		defer root.Close()
		resolved = filepath.Join(resolved, entry.Inside)
		if _, err := root.Lstat(entry.Inside); err != nil {
			return fmt.Errorf("打开源文件 %s: %w", resolved, err)
		}
	}
	return reveal(resolved)
}
