package platform

import "sync"

var transferActivity sharedActivity

// BeginTransferActivity holds one native idle-sleep assertion while any
// transfer is active. The last caller to release it ends the assertion.
func BeginTransferActivity() (func(), error) {
	return transferActivity.acquire(beginTransferActivity)
}

type sharedActivity struct {
	mu      sync.Mutex
	users   int
	release func()
}

func (a *sharedActivity) acquire(begin func() (func(), error)) (func(), error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.users == 0 {
		release, err := begin()
		if err != nil {
			return nil, err
		}
		a.release = release
	}
	a.users++
	return sync.OnceFunc(func() {
		a.mu.Lock()
		defer a.mu.Unlock()
		a.users--
		if a.users == 0 {
			a.release()
			a.release = nil
		}
	}), nil
}
