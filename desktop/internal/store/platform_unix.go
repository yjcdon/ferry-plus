//go:build darwin || linux

package store

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
)

func acquireLock(path string) (*os.File, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, ErrInUse
		}
		return nil, err
	}
	return file, nil
}

func replaceFile(src, dst string) error {
	if err := os.Rename(src, dst); err != nil {
		return err
	}
	return syncDirectory(filepath.Dir(dst))
}

func syncDirectory(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
