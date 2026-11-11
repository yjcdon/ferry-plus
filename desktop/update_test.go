package main

import (
	"context"
	"errors"
	"sync"
	"testing"
)

func TestUpdateInstallKeepsExitBarrierDuringFileSwap(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	var barrier sync.Mutex
	started, release := make(chan struct{}), make(chan struct{})
	done := make(chan error, 1)
	go func() {
		done <- installUpdate(ctx, &barrier, func(ctx context.Context) error {
			close(started)
			<-release // The updater's file swap continues after network cancellation.
			return ctx.Err()
		})
	}()
	<-started
	cancel()
	if barrier.TryLock() {
		barrier.Unlock()
		t.Error("exit reached the barrier while the file swap was still running")
	}
	close(release)
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("install returned %v after cancellation", err)
	}
	if err := installUpdate(ctx, &barrier, func(context.Context) error {
		t.Fatal("install started after shutdown cancellation")
		return nil
	}); !errors.Is(err, context.Canceled) {
		t.Fatalf("new install returned %v after cancellation", err)
	}
}
