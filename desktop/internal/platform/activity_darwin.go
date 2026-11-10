package platform

import (
	"errors"
	"sync"

	"github.com/ebitengine/purego/objc"
)

// BeginTransferActivity keeps the Mac awake through idle periods while a
// transfer worker runs. The token is released when that activity ends.
func BeginTransferActivity() (release func(), err error) {
	defer objcPool()()
	const idleSystemSleepDisabled = uint64(1 << 20)
	process := objcSend[objc.ID](objcClass("NSProcessInfo"), "processInfo")
	token := objcSend[objc.ID](process, "beginActivityWithOptions:reason:",
		idleSystemSleepDisabled, objcString("Ferry Drive 正在传输文件"))
	if token == 0 {
		return nil, errors.New("无法保持系统唤醒")
	}
	objcSend[uintptr](token, "retain")
	return sync.OnceFunc(func() {
		defer objcPool()()
		objcSend[uintptr](process, "endActivity:", token)
		objcSend[uintptr](token, "release")
	}), nil
}
