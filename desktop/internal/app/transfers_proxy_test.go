package app

import (
	"context"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/core"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

func TestChangeProxyWaitsForCheckpointAndAppliesLatest(t *testing.T) {
	accounts := &Accounts{}
	session := transferTestSession(accounts, "owner")
	target := DirectoryTarget{Ref: Baidu.RootRef(), AccountID: session.ID, session: session}
	started, stopped := make(chan string, 3), make(chan string, 1)
	release := make(chan struct{})
	var unblock sync.Once
	var attempts, proxy atomic.Int32
	runner := uploadTestWorker(func(ctx context.Context, req core.UploadRequest, _ core.UploadProviders, _ func(core.UploadProgress)) (core.UploadResult, error) {
		attempt := attempts.Add(1)
		started <- req.ID
		if attempt == 1 {
			<-ctx.Done()
			stopped <- req.ID
			<-release
			return core.UploadResult{}, ctx.Err()
		}
		if proxy.Load() != 2 {
			t.Error("旧任务恢复时应使用最后一次代理配置")
		}
		return core.UploadResult{}, nil
	})
	queue, err := newTransfers(&transferTestRecords{}, accounts, runner, nil, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		unblock.Do(func() { close(release) })
		queue.Close()
	}()
	add := func(name string) string {
		t.Helper()
		id, err := queue.EnqueueUpload(target, []platform.LocalReference{{Path: filepath.Join(t.TempDir(), name)}})
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	active := add("活动")
	if takeTransferID(t, started) != active {
		t.Fatal("活动任务未启动")
	}
	paused := add("手动暂停")
	if err := queue.Pause(paused); err != nil {
		t.Fatal(err)
	}
	queue.ChangeProxy(func() { t.Error("收尾期间较早的代理配置应被替换") })
	if takeTransferID(t, stopped) != active {
		t.Fatal("代理变更未让活动任务收尾")
	}
	queue.ChangeProxy(func() { proxy.Store(2) })
	if proxy.Load() != 0 || attempts.Load() != 1 {
		t.Fatal("代理变更或新执行者绕过了收尾屏障")
	}
	unblock.Do(func() { close(release) })
	if takeTransferID(t, started) != active {
		t.Fatal("未恢复原活动任务")
	}
	waitTransferState(t, queue, active, TransferCompleted)
	waitTransferState(t, queue, paused, TransferPaused)
}
