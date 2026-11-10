package download

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

// Discard clears a stopped file's checkpoint and its private partial file.
// A published destination or publication candidate always remains untouched.
func (e *Engine) Discard(req Request) error {
	rel, err := platform.DownloadRelativePath(req.RelativePath)
	if err != nil {
		return err
	}
	name, release, err := e.claim(req.ID)
	if err != nil {
		return err
	}
	defer release()
	var saved checkpoint
	if err := e.records.Read(name, &saved); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		return err
	}
	if saved.Target != rel || saved.Folder != filepath.Clean(req.Folder.Path) || saved.Size != req.Size ||
		!localName(saved.Partial) || !strings.HasPrefix(saved.Partial, ".ferry-") ||
		!strings.HasSuffix(saved.Partial, ".part") || saved.Partial == saved.Candidate {
		return errors.New("下载断点与当前文件不一致")
	}
	access, err := platform.OpenLocalItem(req.Folder)
	if err != nil {
		return err
	}
	defer access.Close()
	root, err := os.OpenRoot(access.Reference.Path)
	if err != nil {
		return err
	}
	defer root.Close()
	partial := filepath.Join(filepath.Dir(rel), saved.Partial)
	info, err := root.Lstat(partial)
	if err == nil {
		if !info.Mode().IsRegular() {
			return errors.New("下载临时路径不是普通文件")
		}
		if err := root.Remove(partial); err != nil {
			return fmt.Errorf("清理下载临时文件: %w", err)
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return e.records.Remove(name)
}
