package ui

import (
	"errors"
	"fmt"
	"path/filepath"
	"runtime"
	"slices"
	"strings"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

func transferRevealLabel() string {
	if runtime.GOOS == "darwin" {
		return "在访达中显示"
	}
	return "在资源管理器中显示"
}

// transferRevealPaths locates each selected top-level download using its actual final path,
// including collision-renamed files. Trashed items and upload source files are excluded.
func transferRevealPaths(job app.TransferJob) []string {
	if job.Direction != app.TransferDownload {
		return nil
	}
	var paths []string
	for _, item := range job.Items {
		if item.LocalPath == "" || item.Trashed {
			continue
		}
		path := item.LocalPath
		for range strings.Count(item.RelativePath, "/") {
			path = filepath.Dir(path)
		}
		if !slices.Contains(paths, path) {
			paths = append(paths, path)
		}
	}
	return paths
}

// revealTransfer re-reads the current job before opening its downloaded items in the system file manager.
func (w *Workspace) revealTransfer(id string) error {
	for _, job := range w.jobs.Snapshot() {
		if job.ID != id {
			continue
		}
		var failures []error
		for _, path := range transferRevealPaths(job) {
			if err := platform.RevealLocalItem(path); err != nil {
				failures = append(failures, fmt.Errorf("%s：%w", path, err))
			}
		}
		return errors.Join(failures...)
	}
	return errors.New("找不到传输任务")
}
