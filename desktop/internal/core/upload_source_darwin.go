package core

import (
	"os"
	"syscall"
)

const uploadOpenFlags = os.O_RDONLY | syscall.O_NOFOLLOW | syscall.O_NONBLOCK
