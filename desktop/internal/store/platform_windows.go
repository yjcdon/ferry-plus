package store

import (
	"errors"
	"os"
	"strings"
	"syscall"
	"unsafe"
)

const (
	errorSharingViolation   syscall.Errno = 32
	moveFileReplaceExisting               = 0x1
	moveFileWriteThrough                  = 0x8
)

var moveFileEx = syscall.NewLazyDLL("kernel32.dll").NewProc("MoveFileExW")

func acquireLock(path string) (*os.File, error) {
	name, err := syscall.UTF16PtrFromString(extendedPath(path))
	if err != nil {
		return nil, err
	}
	// Share mode zero makes the lock file exclusive until the handle closes.
	handle, err := syscall.CreateFile(name, syscall.GENERIC_READ|syscall.GENERIC_WRITE,
		0, nil, syscall.OPEN_ALWAYS, syscall.FILE_ATTRIBUTE_NORMAL, 0)
	if errors.Is(err, errorSharingViolation) {
		return nil, ErrInUse
	}
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(handle), path), nil
}

func replaceFile(src, dst string) error {
	from, err := syscall.UTF16PtrFromString(extendedPath(src))
	if err != nil {
		return err
	}
	to, err := syscall.UTF16PtrFromString(extendedPath(dst))
	if err != nil {
		return err
	}
	ok, _, err := moveFileEx.Call(uintptr(unsafe.Pointer(from)), uintptr(unsafe.Pointer(to)),
		moveFileReplaceExisting|moveFileWriteThrough)
	if ok == 0 {
		return err
	}
	return nil
}

// The store directory is absolute. Use Win32 extended paths for user
// profiles whose full record paths exceed the traditional MAX_PATH.
func extendedPath(path string) string {
	switch {
	case strings.HasPrefix(path, `\\?\`):
		return path
	case strings.HasPrefix(path, `\\`):
		return `\\?\UNC\` + path[2:]
	default:
		return `\\?\` + path
	}
}

// MoveFileEx requests write-through. Windows doesn't support fsync on
// a directory handle, and DeleteFile commits removal when the handle closes.
func syncDirectory(string) error { return nil }
