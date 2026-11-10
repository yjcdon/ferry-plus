package download

import (
	"os"
	"runtime"
	"syscall"

	"github.com/ebitengine/purego"
)

func publishExclusive(root *os.Root, from, to string, _ *fileStamp) (*fileStamp, error) {
	dir, err := root.Open(".")
	if err != nil {
		return nil, err
	}
	defer dir.Close()

	var rename func(int32, string, int32, string, uint32) int32
	var errno func() *int32
	purego.RegisterLibFunc(&rename, purego.RTLD_DEFAULT, "renameatx_np")
	purego.RegisterLibFunc(&errno, purego.RTLD_DEFAULT, "__error")
	fd := int32(dir.Fd())
	const renameExcl = 0x4 // RENAME_EXCL, same no-overwrite operation as Swift.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if rename(fd, from, fd, to, renameExcl) != 0 {
		return nil, syscall.Errno(*errno())
	}
	return nil, nil
}

func publicationStamp(_ *os.Root, _ string, info os.FileInfo) (*fileStamp, error) {
	stat := info.Sys().(*syscall.Stat_t)
	if stat.Ino == 0 {
		return nil, nil
	}
	return &fileStamp{Inode: stat.Ino, Birth: stat.Birthtimespec.Nano(), Modified: stat.Mtimespec.Nano()}, nil
}

func syncPublishDirectory(root *os.Root) error {
	dir, err := root.Open(".")
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
