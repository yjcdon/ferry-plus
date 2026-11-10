package download

import (
	"errors"
	"os"
	"syscall"
	"unsafe"
)

var (
	publishNTDLL         = syscall.NewLazyDLL("ntdll.dll")
	publishNTOpenFile    = publishNTDLL.NewProc("NtOpenFile")
	publishNTSetInfo     = publishNTDLL.NewProc("NtSetInformationFile")
	publishNTStatusToDOS = publishNTDLL.NewProc("RtlNtStatusToDosError")
)

type publishUnicodeString struct {
	Length, MaximumLength uint16
	Buffer                *uint16
}

type publishObjectAttributes struct {
	Length             uint32
	RootDirectory      syscall.Handle
	ObjectName         *publishUnicodeString
	Attributes         uint32
	SecurityDescriptor uintptr
	SecurityQoS        uintptr
}

type publishIOStatusBlock struct {
	Status, Information uintptr
}

type publishRenameInfo struct {
	ReplaceIfExists byte
	RootDirectory   syscall.Handle
	FileNameLength  uint32
	FileName        [syscall.MAX_PATH]uint16
}

// Rename a regular file by handle relative to the selected directory. The
// classic information class supports FAT volumes and defaults to no replace.
func publishExclusive(root *os.Root, from, to string, expected *fileStamp) (*fileStamp, error) {
	if !localName(from) || !localName(to) {
		return nil, syscall.EINVAL
	}
	oldName, err := syscall.UTF16FromString(from)
	if err != nil {
		return nil, err
	}
	newName, err := syscall.UTF16FromString(to)
	if err != nil {
		return nil, err
	}
	if len(oldName) > syscall.MAX_PATH || len(newName) > syscall.MAX_PATH {
		return nil, syscall.ENAMETOOLONG
	}
	dir, err := root.Open(".")
	if err != nil {
		return nil, err
	}
	defer dir.Close()

	const (
		caseInsensitive       = 0x40
		fileReadAttributes    = 0x80
		fileDelete            = 0x10000
		synchronize           = 0x100000
		fileSynchronous       = 0x20
		fileNonDirectory      = 0x40
		fileBackupIntent      = 0x4000
		fileOpenReparsePoint  = 0x200000
		fileRenameInformation = 10
	)
	name := publishUnicodeString{uint16((len(oldName) - 1) * 2), uint16(len(oldName) * 2), &oldName[0]}
	attrs := publishObjectAttributes{
		Length:        uint32(unsafe.Sizeof(publishObjectAttributes{})),
		RootDirectory: syscall.Handle(dir.Fd()),
		ObjectName:    &name,
		Attributes:    caseInsensitive,
	}
	var handle syscall.Handle
	var ioStatus publishIOStatusBlock
	status, _, _ := publishNTOpenFile.Call(uintptr(unsafe.Pointer(&handle)), synchronize|fileDelete|fileReadAttributes,
		uintptr(unsafe.Pointer(&attrs)), uintptr(unsafe.Pointer(&ioStatus)), syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE|syscall.FILE_SHARE_DELETE,
		fileSynchronous|fileNonDirectory|fileBackupIntent|fileOpenReparsePoint)
	if err := publicationNTError(status); err != nil {
		return nil, err
	}
	defer syscall.CloseHandle(handle)
	actual, err := stampWindowsHandle(handle)
	if err != nil {
		return nil, err
	}
	if expected != nil && *actual != *expected {
		return nil, errors.New("下载临时文件与发布记录不一致")
	}

	// A leaf with a null RootDirectory renames within the source directory.
	rename := publishRenameInfo{FileNameLength: uint32((len(newName) - 1) * 2)}
	copy(rename.FileName[:], newName)
	status, _, _ = publishNTSetInfo.Call(uintptr(handle), uintptr(unsafe.Pointer(&ioStatus)), uintptr(unsafe.Pointer(&rename)),
		unsafe.Sizeof(rename), fileRenameInformation)
	if err := publicationNTError(status); err != nil {
		return nil, err
	}
	// FAT can change the ID when the destination name needs more directory slots.
	// Read the final identity on the same open handle before saving the receipt.
	return stampWindowsHandle(handle)
}

func publicationNTError(status uintptr) error {
	if uint32(status) == 0 {
		return nil
	}
	code, _, _ := publishNTStatusToDOS.Call(uintptr(uint32(status)))
	return syscall.Errno(code)
}

func publicationStamp(root *os.Root, name string, info os.FileInfo) (*fileStamp, error) {
	file, err := root.Open(name)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	actual, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !os.SameFile(info, actual) {
		return nil, errors.New("下载文件与发布记录不一致")
	}
	return stampWindowsHandle(syscall.Handle(file.Fd()))
}

func stampWindowsHandle(handle syscall.Handle) (*fileStamp, error) {
	var info syscall.ByHandleFileInformation
	if err := syscall.GetFileInformationByHandle(handle, &info); err != nil {
		return nil, err
	}
	id := uint64(info.FileIndexHigh)<<32 | uint64(info.FileIndexLow)
	if id == 0 || info.FileAttributes&(syscall.FILE_ATTRIBUTE_DIRECTORY|syscall.FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
		return nil, errors.New("无法确认下载文件的标识")
	}
	return &fileStamp{Inode: id, Volume: uint64(info.VolumeSerialNumber), Birth: info.CreationTime.Nanoseconds(), Modified: info.LastWriteTime.Nanoseconds()}, nil
}

// Windows has no supported directory fsync. The temporary file and the
// versioned completion record are flushed separately.
func syncPublishDirectory(*os.Root) error { return nil }
