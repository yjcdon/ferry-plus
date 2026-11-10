package download

import (
	"os"
	"runtime"
	"syscall"

	"github.com/ebitengine/purego"
)

func publishExclusive(root *os.Root, from, to string) error {
	dir, err := root.Open(".")
	if err != nil {
		return err
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
		return syscall.Errno(*errno())
	}
	return nil
}

func publicationStamp(info os.FileInfo) *fileStamp {
	stat := info.Sys().(*syscall.Stat_t)
	if stat.Ino == 0 {
		return nil
	}
	return &fileStamp{Inode: stat.Ino, Birth: stat.Birthtimespec.Nano(), Modified: stat.Mtimespec.Nano()}
}

func syncPublishDirectory(root *os.Root) error {
	dir, err := root.Open(".")
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
