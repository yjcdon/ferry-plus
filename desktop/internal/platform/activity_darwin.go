package platform

import (
	"errors"

	"github.com/ebitengine/purego/objc"
)

func beginTransferActivity() (release func(), err error) {
	defer objcPool()()
	const idleSystemSleepDisabled = uint64(1 << 20)
	process := objcSend[objc.ID](objcClass("NSProcessInfo"), "processInfo")
	token := objcSend[objc.ID](process, "beginActivityWithOptions:reason:",
		idleSystemSleepDisabled, objcString("Ferry Drive 正在传输文件"))
	if token == 0 {
		return nil, errors.New("无法保持系统唤醒")
	}
	objcSend[uintptr](token, "retain")
	return func() {
		defer objcPool()()
		objcSend[uintptr](process, "endActivity:", token)
		objcSend[uintptr](token, "release")
	}, nil
}
