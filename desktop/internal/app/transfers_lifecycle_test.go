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

func TestTransferSleepWakeKeepsManualPauseAndActivity(t *testing.T) {
	accounts, records := &Accounts{}, &transferTestRecords{}
	session := transferTestSession(accounts, "owner")
	started := make(chan string, 3)
	interrupted := make(chan string, 1)
	allowExit := make(chan struct{})
	var unblock sync.Once
	var activity, acquired atomic.Int32
	attempts := 0
	runner := uploadTestWorker(func(ctx context.Context, req core.UploadRequest, _ core.UploadProviders, _ func(core.UploadProgress)) (core.UploadResult, error) {
		attempts++
		if activity.Load() != 1 {
			t.Error("只应为当前执行者保留唤醒活动")
		}
		started <- req.ID
		if attempts == 1 {
			<-ctx.Done()
			interrupted <- req.ID
			<-allowExit
			return core.UploadResult{}, ctx.Err()
		}
		return core.UploadResult{}, nil
	})
	transfers, err := newTransfers(records, accounts, runner, nil, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		unblock.Do(func() { close(allowExit) })
		transfers.Close()
	}()
	transfers.beginActivity = func() (func(), error) {
		acquired.Add(1)
		activity.Add(1)
		return func() { activity.Add(-1) }, nil
	}
	target := DirectoryTarget{Ref: Baidu.RootRef(), AccountID: session.ID, session: session}
	add := func(name string) string {
		t.Helper()
		id, err := transfers.EnqueueUpload(target, []platform.LocalReference{{Path: filepath.Join(t.TempDir(), name)}})
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	running := add("运行")
	if takeTransferID(t, started) != running {
		t.Fatal("运行任务未启动")
	}
	manual := add("手动暂停")
	if err := transfers.Pause(manual); err != nil {
		t.Fatal(err)
	}

	transfers.Suspend()
	if takeTransferID(t, interrupted) != running {
		t.Fatal("休眠没有停止当前执行者")
	}
	transfers.Wake()
	select {
	case <-started:
		t.Fatal("唤醒不能绕过旧执行者的保存屏障")
	default:
	}
	unblock.Do(func() { close(allowExit) })
	if takeTransferID(t, started) != running {
		t.Fatal("唤醒恢复了错误的任务")
	}
	waitTransferState(t, transfers, running, TransferCompleted)
	waitTransferState(t, transfers, manual, TransferPaused)
	transfers.Close()
	if activity.Load() != 0 || acquired.Load() != 2 {
		t.Fatalf("唤醒活动释放不符: 当前 %d，取得 %d", activity.Load(), acquired.Load())
	}
}
