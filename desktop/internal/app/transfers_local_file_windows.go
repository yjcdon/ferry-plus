package app

import (
	"errors"
	"os"
	"syscall"
)

func downloadIdentity(file *os.File, _ os.FileInfo) (downloadFileIdentity, error) {
	var info syscall.ByHandleFileInformation
	if err := syscall.GetFileInformationByHandle(syscall.Handle(file.Fd()), &info); err != nil {
		const invalidFunction, notSupported = syscall.Errno(1), syscall.Errno(50)
		if errors.Is(err, invalidFunction) || errors.Is(err, notSupported) {
			return downloadFileIdentity{}, nil
		}
		return downloadFileIdentity{}, err
	}
	return downloadFileIdentity{
		ID: uint64(info.FileIndexHigh)<<32 | uint64(info.FileIndexLow), Volume: info.VolumeSerialNumber,
		Birth: info.CreationTime.Nanoseconds(), Modified: info.LastWriteTime.Nanoseconds(),
	}, nil
}
