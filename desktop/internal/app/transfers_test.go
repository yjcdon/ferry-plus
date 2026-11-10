package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
	"github.com/yjcdon/ferry-drive/desktop/internal/core"
	"github.com/yjcdon/ferry-drive/desktop/internal/download"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

type transferTestRecords struct {
	mu   sync.Mutex
	data []byte
	fail bool
}

func (r *transferTestRecords) Read(_ string, dst any) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.data == nil {
		return fs.ErrNotExist
	}
	return json.Unmarshal(r.data, dst)
}

func (r *transferTestRecords) Write(_ string, value any) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.fail {
		return errors.New("测试保存失败")
	}
	data, err := json.Marshal(value)
	if err == nil {
		r.data = data
	}
	return err
}

type uploadTestWorker func(context.Context, core.UploadRequest, core.UploadProviders, func(core.UploadProgress)) (core.UploadResult, error)

func (run uploadTestWorker) Run(ctx context.Context, req core.UploadRequest, providers core.UploadProviders, progress func(core.UploadProgress)) (core.UploadResult, error) {
	return run(ctx, req, providers, progress)
}

func downloadedFixture(req download.Request) (download.Result, error) {
	path := filepath.Join(req.Folder.Path, req.RelativePath)
	if err := os.WriteFile(path, make([]byte, req.Size), 0o600); err != nil {
		return download.Result{}, err
	}
	return download.Result{Path: path, Folder: req.Folder}, nil
}

type downloadTestWorker struct {
	run     func(download.Request) (download.Result, error)
	ack     func(string) error
	discard func(download.Request) error
}

func (w downloadTestWorker) Run(_ context.Context, req download.Request, _ download.Resolve, _ func(int64, int64)) (download.Result, error) {
	return w.run(req)
}

func (w downloadTestWorker) Acknowledge(id string) error {
	if w.ack == nil {
		return nil
	}
	return w.ack(id)
}

func (w downloadTestWorker) Discard(req download.Request) error {
	if w.discard == nil {
		return nil
	}
	return w.discard(req)
}

func transferTestSession(accounts *Accounts, id string) AccountSession {
	session := AccountSession{State: LoggedIn, ID: id, Name: "测试账号"}
	accounts.slot(Baidu).current.Store(&session)
	return session
}

func waitTransferState(t *testing.T, transfers *Transfers, id string, want TransferState) TransferJob {
	t.Helper()
	deadline := time.After(2 * time.Second)
	for {
		for _, job := range transfers.Snapshot() {
			if job.ID == id && job.State == want && !job.Stopping {
				return job
			}
		}
		select {
		case <-deadline:
			t.Fatalf("任务 %s 未进入 %s: %+v", id, want, transfers.Snapshot())
		case <-time.After(time.Millisecond):
		}
	}
}

func takeTransferID(t *testing.T, ch <-chan string) string {
	t.Helper()
	select {
	case id := <-ch:
		return id
	case <-time.After(2 * time.Second):
		t.Fatal("任务未开始")
		return ""
	}
}

func TestTransferPausePersistsBeforeCancelAndWaitsForBarrier(t *testing.T) {
	accounts, records := &Accounts{}, &transferTestRecords{}
	session := transferTestSession(accounts, "owner")
	starts := make(chan string, 3)
	stopped := make(chan string, 1)
	allowExit := make(chan struct{})
	var release sync.Once
	defer release.Do(func() { close(allowExit) })
	calls := 0
	worker := uploadTestWorker(func(ctx context.Context, req core.UploadRequest, providers core.UploadProviders, _ func(core.UploadProgress)) (core.UploadResult, error) {
		calls++
		starts <- req.ID
		if providers.AccountID != session.ID {
			t.Error("上传执行者收到错误账号")
		}
		if calls == 1 {
			<-ctx.Done()
			var rows []transferRecord
			if err := records.Read(transferRecordName, &rows); err != nil || len(rows) != 1 || rows[0].State != TransferPaused {
				t.Errorf("取消时暂停意图尚未保存: %+v, %v", rows, err)
			}
			stopped <- req.ID
			<-allowExit
			return core.UploadResult{}, ctx.Err()
		}
		return core.UploadResult{Items: []core.UploadItemResult{{RelativePath: "样本", Size: 4, FSID: 11, Path: "/样本"}}}, nil
	})
	transfers, err := newTransfers(records, accounts, worker, nil, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		release.Do(func() { close(allowExit) })
		transfers.Close()
	}()
	target := DirectoryTarget{Ref: Baidu.RootRef(), AccountID: session.ID, session: session}
	id, err := transfers.EnqueueUpload(target, []platform.LocalReference{{Path: filepath.Join(t.TempDir(), "样本")}})
	if err != nil || takeTransferID(t, starts) != id {
		t.Fatalf("上传未启动: %s, %v", id, err)
	}
	records.mu.Lock()
	records.fail = true
	records.mu.Unlock()
	if err := transfers.Pause(id); err == nil || transfers.Snapshot()[0].State != TransferRunning {
		t.Fatal("保存失败时不能改变执行中的任务状态")
	}
	records.mu.Lock()
	records.fail = false
	records.mu.Unlock()
	if err := transfers.Pause(id); err != nil {
		t.Fatal(err)
	}
	if takeTransferID(t, stopped) != id {
		t.Fatal("等待暂停的任务不一致")
	}
	if err := transfers.Resume(id); err != nil {
		t.Fatal(err)
	}
	select {
	case <-starts:
		t.Fatal("旧执行者退出之前开始了新任务")
	default:
	}
	release.Do(func() { close(allowExit) })
	if takeTransferID(t, starts) != id {
		t.Fatal("恢复了错误任务")
	}
	job := waitTransferState(t, transfers, id, TransferCompleted)
	if job.Done != 4 || len(job.Items) != 1 || job.Items[0].Remote.ID != "11" {
		t.Fatalf("完成结果不一致: %+v", job)
	}
}

func TestTransferPriorityAndFrozenAccount(t *testing.T) {
	accounts, records := &Accounts{}, &transferTestRecords{}
	owner := transferTestSession(accounts, "owner")
	starts := make(chan string, 4)
	unblock := make(chan struct{})
	first := true
	worker := uploadTestWorker(func(ctx context.Context, req core.UploadRequest, _ core.UploadProviders, _ func(core.UploadProgress)) (core.UploadResult, error) {
		starts <- req.ID
		if first {
			first = false
			select {
			case <-unblock:
			case <-ctx.Done():
				return core.UploadResult{}, ctx.Err()
			}
		}
		return core.UploadResult{}, nil
	})
	transfers, err := newTransfers(records, accounts, worker, nil, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer transfers.Close()
	target := DirectoryTarget{Ref: Baidu.RootRef(), AccountID: owner.ID, session: owner}
	add := func(name string) string {
		t.Helper()
		id, err := transfers.EnqueueUpload(target, []platform.LocalReference{{Path: filepath.Join(t.TempDir(), name)}})
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	firstID := add("一")
	if takeTransferID(t, starts) != firstID {
		t.Fatal("首个上传未开始")
	}
	second, third := add("二"), add("三")
	if err := transfers.Prioritize(third); err != nil {
		t.Fatal(err)
	}
	close(unblock)
	if takeTransferID(t, starts) != third || takeTransferID(t, starts) != second {
		t.Fatal("优先级没有应用到等待中的上传")
	}
	transferTestSession(accounts, "other")
	if _, err := transfers.EnqueueUpload(target, []platform.LocalReference{{Path: t.TempDir()}}); !errors.Is(err, ErrDirectorySessionChanged) {
		t.Fatalf("旧选择使用了切换后的账号: %v", err)
	}
}

func TestTransferDownloadReceiptBeforeAckAndRetryKeepsSuccess(t *testing.T) {
	accounts, records := &Accounts{}, &transferTestRecords{}
	session := transferTestSession(accounts, "owner")
	attempts := map[string]int{}
	worker := downloadTestWorker{
		run: func(req download.Request) (download.Result, error) {
			attempts[req.RelativePath]++
			if req.RelativePath == "二.txt" && attempts[req.RelativePath] == 1 {
				return download.Result{}, errors.New("模拟断网")
			}
			return downloadedFixture(req)
		},
		ack: func(id string) error {
			var rows []transferRecord
			if err := records.Read(transferRecordName, &rows); err != nil {
				return err
			}
			for i, item := range rows[0].Items {
				if id == fmt.Sprintf("%s-%d", rows[0].ID, i) && item.Complete && item.LocalPath != "" {
					return nil
				}
			}
			return errors.New("先清除了下载引擎回执")
		},
	}
	transfers, err := newTransfers(records, accounts, nil, worker, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer transfers.Close()
	folder := platform.LocalReference{Path: t.TempDir()}
	selection := DirectorySelection{Target: DirectoryTarget{Ref: Baidu.RootRef(), AccountID: session.ID, session: session}}
	for i, name := range []string{"一.txt", "二.txt"} {
		selection.Items = append(selection.Items, DirectoryItem{Entry: RemoteEntry{
			Ref: RemoteRef{Provider: Baidu, ID: fmt.Sprint(i + 1), Path: "/" + name}, Name: name, Size: 4,
		}})
	}
	id, err := transfers.EnqueueDownload(selection, folder)
	if err != nil {
		t.Fatal(err)
	}
	failed := waitTransferState(t, transfers, id, TransferFailed)
	if failed.StatusText() != "部分失败" || failed.Done != 4 || !failed.Items[0].Complete {
		t.Fatalf("部分结果未保存: %+v", failed)
	}
	if err := transfers.RetryFailed(id); err != nil {
		t.Fatal(err)
	}
	complete := waitTransferState(t, transfers, id, TransferCompleted)
	if complete.Done != 8 || attempts["一.txt"] != 1 || attempts["二.txt"] != 2 {
		t.Fatalf("重试重复下载已完成项目: %+v, %v", complete, attempts)
	}
	if err := transfers.Remove(id); err != nil || len(transfers.Snapshot()) != 0 {
		t.Fatalf("无法清除完成记录: %v", err)
	}
}

func TestTransferUnverifiedShareKeepsOwnedDirectory(t *testing.T) {
	accounts, records := &Accounts{}, &transferTestRecords{}
	session := transferTestSession(accounts, "owner")
	worker := downloadTestWorker{run: func(req download.Request) (download.Result, error) {
		if req.ExpectedSHA256 != "" || req.ExpectedMD5 != "" {
			t.Fatal("未知校验值被当成可信依据")
		}
		return downloadedFixture(req)
	}}
	transfers, err := newTransfers(records, accounts, nil, worker, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer transfers.Close()
	item := DownloadTaskItem{
		Entry:        RemoteEntry{Ref: RemoteRef{Provider: Baidu, ID: "1", Path: "/file"}, Name: "file", Size: 1, MD5: "00000000000000000000000000000000"},
		RelativePath: "file",
	}
	cleanup := &ShareCleanup{Provider: Baidu, AccountID: session.ID}
	id, err := transfers.EnqueuePreparedDownload(Baidu, session, "分享", []DownloadTaskItem{item}, platform.LocalReference{Path: t.TempDir()}, cleanup)
	if err != nil {
		t.Fatal(err)
	}
	job := waitTransferState(t, transfers, id, TransferCompleted)
	if job.Warning == "" || job.Items[0].Verified {
		t.Fatalf("缺少保留转存文件的结果: %+v", job)
	}
	var rows []transferRecord
	if err := records.Read(transferRecordName, &rows); err != nil || rows[0].Download.Cleanup == nil {
		t.Fatalf("丢失清理记录: %v", err)
	}
}

func TestTransferRestoreWaitsForSameAccountAndPreservesPause(t *testing.T) {
	accounts, records := &Accounts{}, &transferTestRecords{}
	owner := transferTestSession(accounts, "owner")
	active := newTransferJob(Baidu, owner, "恢复", TransferUpload)
	active.State = TransferRunning
	paused := newTransferJob(Baidu, owner, "暂停", TransferUpload)
	paused.State = TransferPaused
	uploadRequest := func(id string) *core.UploadRequest {
		return &core.UploadRequest{ID: id, Target: core.UploadTarget{Provider: string(Baidu), AccountID: owner.ID}}
	}
	if err := records.Write(transferRecordName, []transferRecord{
		{TransferJob: active, Upload: uploadRequest(active.ID)},
		{TransferJob: paused, Upload: uploadRequest(paused.ID)},
	}); err != nil {
		t.Fatal(err)
	}
	transferTestSession(accounts, "other")
	starts := make(chan string, 2)
	worker := uploadTestWorker(func(_ context.Context, req core.UploadRequest, providers core.UploadProviders, _ func(core.UploadProgress)) (core.UploadResult, error) {
		if providers.AccountID != owner.ID {
			t.Errorf("恢复用了其他账号 %q", providers.AccountID)
		}
		starts <- req.ID
		return core.UploadResult{}, nil
	})
	transfers, err := newTransfers(records, accounts, worker, nil, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer transfers.Close()
	transfers.AccountsChanged()
	if state := transfers.Snapshot()[0].State; state != TransferWaitingAccount {
		t.Fatalf("其他账号下恢复状态 %q", state)
	}
	if err := transfers.Resume(paused.ID); err == nil {
		t.Fatal("其他账号可以继续暂停的任务")
	}
	transferTestSession(accounts, owner.ID)
	transfers.AccountsChanged()
	if takeTransferID(t, starts) != active.ID {
		t.Fatal("恢复了错误任务")
	}
	waitTransferState(t, transfers, active.ID, TransferCompleted)
	waitTransferState(t, transfers, paused.ID, TransferPaused)
	select {
	case <-starts:
		t.Fatal("启动了手动暂停的任务")
	default:
	}
}

func TestTransferWaitsForAccountWhenProviderExpires(t *testing.T) {
	accounts := NewAccounts(nil, nil)
	session := transferTestSession(accounts, "owner")
	queue, err := newTransfers(&transferTestRecords{}, accounts, uploadTestWorker(func(
		context.Context, core.UploadRequest, core.UploadProviders, func(core.UploadProgress),
	) (core.UploadResult, error) {
		return core.UploadResult{}, fmt.Errorf("网盘请求: %w", baidu.ErrLoginExpired)
	}), nil, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer queue.Close()
	target := DirectoryTarget{Ref: Baidu.RootRef(), AccountID: session.ID, session: session}
	id, err := queue.EnqueueUpload(target, []platform.LocalReference{{Path: filepath.Join(t.TempDir(), "sample")}})
	if err != nil {
		t.Fatal(err)
	}
	waitTransferState(t, queue, id, TransferWaitingAccount)
	if got := accounts.Session(Baidu); got.State != Expired || got.ID != session.ID {
		t.Fatalf("网盘账号没有进入可重新登录的状态: %+v", got)
	}
}
