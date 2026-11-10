package platform

import (
	"fmt"
	"syscall"
	"unsafe"
)

var (
	powerKernel32      = syscall.NewLazyDLL("kernel32.dll")
	powerCreateRequest = powerKernel32.NewProc("PowerCreateRequest")
	powerSetRequest    = powerKernel32.NewProc("PowerSetRequest")
	powerClearRequest  = powerKernel32.NewProc("PowerClearRequest")
)

// The reason union starts with the simple string pointer. Its remaining
// fields keep the layout of REASON_CONTEXT's larger detailed reason member.
type powerRequestContext struct {
	version, flags uint32
	reason         *uint16
	reasonID       uint32
	reasonCount    uint32
	reasonStrings  uintptr
}

func beginTransferActivity() (release func(), err error) {
	const (
		simpleReason   = 1
		systemRequired = 1
	)
	reason, err := syscall.UTF16PtrFromString("Ferry Drive 正在传输文件")
	if err != nil {
		return nil, err
	}
	context := powerRequestContext{flags: simpleReason, reason: reason}
	handle, _, err := powerCreateRequest.Call(uintptr(unsafe.Pointer(&context)))
	if handle == uintptr(syscall.InvalidHandle) {
		return nil, fmt.Errorf("创建 Windows 唤醒请求：%w", err)
	}
	if ok, _, err := powerSetRequest.Call(handle, systemRequired); ok == 0 {
		syscall.CloseHandle(syscall.Handle(handle))
		return nil, fmt.Errorf("设置 Windows 唤醒请求：%w", err)
	}
	return func() {
		powerClearRequest.Call(handle, systemRequired)
		syscall.CloseHandle(syscall.Handle(handle))
	}, nil
}
