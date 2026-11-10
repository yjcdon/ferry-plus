package app

import (
	"os"
	"syscall"
)

func downloadIdentity(_ *os.File, info os.FileInfo) (downloadFileIdentity, error) {
	stat := info.Sys().(*syscall.Stat_t)
	// Device numbers may change when a bookmarked volume is remounted.
	return downloadFileIdentity{ID: stat.Ino, Birth: stat.Birthtimespec.Nano(), Modified: stat.Mtimespec.Nano()}, nil
}
