package app

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/yjcdon/ferry-drive/desktop/internal/download"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

type downloadBatchRunner func(context.Context, download.Request) (download.Result, error)

func (r downloadBatchRunner) Run(ctx context.Context, req download.Request, _ download.Resolve, _ func(int64, int64)) (download.Result, error) {
	return r(ctx, req)
}
func (downloadBatchRunner) Acknowledge(string) error { return nil }

func enqueueTestDownload(t *testing.T, transfers *Transfers, session AccountSession, prefix string, count int) string {
	t.Helper()
	selection := DirectorySelection{Target: DirectoryTarget{Ref: Baidu.RootRef(), AccountID: session.ID, session: session}}
	for i := range count {
		name := fmt.Sprintf("%s-%d.txt", prefix, i)
		selection.Items = append(selection.Items, DirectoryItem{Entry: RemoteEntry{
			Ref: RemoteRef{Provider: Baidu, ID: fmt.Sprint(i + 1), Path: "/" + name}, Name: name, Size: 4,
		}})
	}
	id, err := transfers.EnqueueDownload(selection, platform.LocalReference{Path: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func TestDownloadBatchSharesConfiguredFilesAndConnections(t *testing.T) {
	accounts, records := &Accounts{}, &transferTestRecords{}
	session := transferTestSession(accounts, "owner")
	started := make(chan string, 5)
	gate := make(chan struct{})
	var unblock sync.Once
	var files, connections atomic.Int32
	runner := downloadBatchRunner(func(ctx context.Context, req download.Request) (download.Result, error) {
		count := files.Add(1)
		taken := connections.Add(int32(req.Connections))
		defer files.Add(-1)
		defer connections.Add(-int32(req.Connections))
		if count > 2 || taken > TotalDownloadConnections || req.Connections != 10 {
			t.Errorf("同时下载 %d 文件、%d 连接，当前文件 %d 连接", count, taken, req.Connections)
		}
		started <- req.ID
		select {
		case <-gate:
			return download.Result{Path: filepath.Join(req.Folder.Path, req.RelativePath)}, nil
		case <-ctx.Done():
			return download.Result{}, ctx.Err()
		}
	})
	transfers, err := newTransfers(records, accounts, nil, runner, TransferConfig{DownloadFiles: 2, BaiduConnections: 10}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		unblock.Do(func() { close(gate) })
		transfers.Close()
	}()

	first := enqueueTestDownload(t, transfers, session, "第一批", 3)
	for range 2 {
		if id := takeTransferID(t, started); !strings.HasPrefix(id, first+"-") {
			t.Fatalf("同一批次未开始并发下载: %s", id)
		}
	}
	second := enqueueTestDownload(t, transfers, session, "第二批", 2)
	select {
	case id := <-started:
		t.Fatalf("达到全局文件额度后仍启动 %s", id)
	case <-time.After(20 * time.Millisecond):
	}
	unblock.Do(func() { close(gate) })
	waitTransferState(t, transfers, first, TransferCompleted)
	waitTransferState(t, transfers, second, TransferCompleted)
}

func TestDownloadBatchPauseRetainsCompletedResultBeforeRestart(t *testing.T) {
	accounts, records := &Accounts{}, &transferTestRecords{}
	session := transferTestSession(accounts, "owner")
	started := make(chan string, 4)
	allowExit := make(chan struct{})
	var unblock sync.Once
	var secondRuns atomic.Int32
	runner := downloadBatchRunner(func(ctx context.Context, req download.Request) (download.Result, error) {
		started <- req.RelativePath
		result := download.Result{Path: filepath.Join(req.Folder.Path, req.RelativePath)}
		if req.RelativePath == "批次-0.txt" {
			<-ctx.Done()
			return result, nil // The engine had already committed this file.
		}
		if secondRuns.Add(1) == 1 {
			<-ctx.Done()
			<-allowExit
			return download.Result{}, ctx.Err()
		}
		return result, nil
	})
	transfers, err := newTransfers(records, accounts, nil, runner, TransferConfig{DownloadFiles: 2}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		unblock.Do(func() { close(allowExit) })
		transfers.Close()
	}()

	id := enqueueTestDownload(t, transfers, session, "批次", 2)
	if first, second := takeTransferID(t, started), takeTransferID(t, started); first == second {
		t.Fatal("启动了同一个文件两次")
	}
	if err := transfers.Pause(id); err != nil {
		t.Fatal(err)
	}
	if err := transfers.Resume(id); err != nil {
		t.Fatal(err)
	}
	select {
	case <-started:
		t.Fatal("旧批次退出之前启动了新执行者")
	default:
	}
	unblock.Do(func() { close(allowExit) })
	if got := takeTransferID(t, started); got != "批次-1.txt" {
		t.Fatalf("重复下载已发布文件 %s", got)
	}
	job := waitTransferState(t, transfers, id, TransferCompleted)
	if job.Done != 8 || secondRuns.Load() != 2 || !job.Items[0].Complete || !job.Items[1].Complete {
		t.Fatalf("续传结果不完整: %+v", job)
	}
}

func TestDownloadSlotsPreserveGlobalConnectionsAcrossSettingsChange(t *testing.T) {
	transfers := &Transfers{config: normalizedTransferConfig(TransferConfig{DownloadFiles: 1, BaiduConnections: 16})}
	first, release, err := transfers.takeDownloadSlot(t.Context(), Baidu)
	if err != nil || first != 16 {
		t.Fatalf("初始连接数 %d: %v", first, err)
	}
	defer func() {
		if release != nil {
			release()
		}
	}()
	transfers.Configure(TransferConfig{DownloadFiles: 4, BaiduConnections: 5, QuarkConnections: 5})
	granted := make(chan int, 1)
	go func() {
		n, done, err := transfers.takeDownloadSlot(t.Context(), Quark)
		if err != nil {
			return
		}
		defer done()
		granted <- n
	}()
	select {
	case n := <-granted:
		t.Fatalf("旧文件占用 16 连接时仍授予 %d 连接", n)
	case <-time.After(20 * time.Millisecond):
	}
	release()
	release = nil
	select {
	case n := <-granted:
		if n != 5 {
			t.Fatalf("未按新设置保留每文件连接数: %d", n)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("连接释放后未唤醒等待者")
	}
}
