package app

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/core"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

type rebindTestRunner struct {
	uploadTestWorker
	rebind func(context.Context, string, string, platform.LocalReference) error
}

func (r rebindTestRunner) RebindSource(ctx context.Context, id, relative string, source platform.LocalReference) error {
	return r.rebind(ctx, id, relative, source)
}

func TestUploadRebindKeepsPauseAndBlocksConflictingActions(t *testing.T) {
	const id, relative = "upload", "资料/报告.txt"
	accounts := NewAccounts(nil, nil)
	owner := transferTestSession(accounts, "owner")
	records := &transferTestRecords{}
	originalPath := filepath.Join(t.TempDir(), "old.txt")
	wrongPath := filepath.Join(t.TempDir(), "wrong.txt")
	replacementPath := filepath.Join(t.TempDir(), "moved.txt")
	job := newTransferJob(Baidu, owner, "上传样本", TransferUpload)
	job.ID, job.State = id, TransferPaused
	job.Items = []TransferItem{
		{RelativePath: relative, Error: "原文件已移动", CanRebind: true},
		{RelativePath: "资料/已上传.txt", Complete: true, Verified: true},
		{RelativePath: "资料/其他失败.txt", Error: "另一项失败"},
	}
	record := transferRecord{TransferJob: job, Upload: &core.UploadRequest{
		ID: id, Target: core.UploadTarget{Provider: string(Baidu), AccountID: owner.ID, Path: "/"},
		Sources: []platform.LocalReference{{Path: originalPath}},
	}}
	if err := records.Write(transferRecordName, []transferRecord{record}); err != nil {
		t.Fatal(err)
	}
	started, resume := make(chan struct{}), make(chan struct{})
	runner := rebindTestRunner{
		uploadTestWorker: func(context.Context, core.UploadRequest, core.UploadProviders, func(core.UploadProgress)) (core.UploadResult, error) {
			t.Error("manual pause was not preserved")
			return core.UploadResult{}, nil
		},
		rebind: func(ctx context.Context, gotID, gotPath string, source platform.LocalReference) error {
			if gotID != id || gotPath != relative {
				return errors.New("changed frozen source item")
			}
			if source.Path == wrongPath {
				return core.ErrUploadSourceChanged
			}
			if source.Path != replacementPath {
				return errors.New("unexpected selected file")
			}
			close(started)
			select {
			case <-resume:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		},
	}
	queue, err := newTransfers(records, accounts, runner, nil, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer queue.Close()
	if err := queue.RebindUploadSource(t.Context(), id, relative, platform.LocalReference{Path: wrongPath}); !errors.Is(err, core.ErrUploadSourceChanged) {
		t.Fatalf("wrong source error = %v", err)
	}
	if got := queue.Snapshot()[0]; got.Items[0].Error != job.Items[0].Error || !got.Items[0].CanRebind {
		t.Fatalf("wrong source changed saved row: %+v", got)
	}

	done := make(chan error, 1)
	go func() {
		done <- queue.RebindUploadSource(t.Context(), id, relative, platform.LocalReference{Path: replacementPath})
	}()
	<-started
	if got := queue.Snapshot()[0]; got.RebindingPath != relative || !got.Stopping {
		t.Fatalf("in-flight rebind state = %+v", got)
	}
	if err := queue.Resume(id); err == nil {
		t.Fatal("continued while the source was being checked")
	}
	if err := queue.Cancel(id); err == nil {
		t.Fatal("canceled while the source was being checked")
	}
	close(resume)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	got := waitTransferState(t, queue, id, TransferPaused)
	if got.Items[0].Error != "" || got.Items[0].CanRebind || got.Items[1] != job.Items[1] || got.Items[2] != job.Items[2] {
		t.Fatalf("rebind changed other files or left its original error: %+v", got)
	}
	var persisted []transferRecord
	if err := records.Read(transferRecordName, &persisted); err != nil || persisted[0].Upload.Sources[0].Path != originalPath {
		t.Fatalf("original request was changed: %+v err=%v", persisted, err)
	}
}

func TestUploadFailedSourceRebindSchedulesOriginalRequest(t *testing.T) {
	const id, relative = "upload", "报告.txt"
	accounts := NewAccounts(nil, nil)
	owner := transferTestSession(accounts, "owner")
	records := &transferTestRecords{}
	request := core.UploadRequest{ID: id, Target: core.UploadTarget{Provider: string(Baidu), AccountID: owner.ID, Path: "/folder", FSID: 42},
		Sources: []platform.LocalReference{{Path: filepath.Join(t.TempDir(), "old.txt")}}}
	job := newTransferJob(Baidu, owner, relative, TransferUpload)
	job.ID = id
	seen := make(chan core.UploadRequest, 2)
	runner := rebindTestRunner{
		uploadTestWorker: func(_ context.Context, req core.UploadRequest, _ core.UploadProviders, _ func(core.UploadProgress)) (core.UploadResult, error) {
			seen <- req
			if len(seen) == 1 {
				// This first attempt fails at the file level. A successful rebind
				// allows the second attempt to finish without changing its target.
				return core.UploadResult{Items: []core.UploadItemResult{{RelativePath: relative, CanRebind: true, Error: "原文件已移动"}}}, core.ErrUploadSourceChanged
			}
			return core.UploadResult{}, nil
		},
		rebind: func(context.Context, string, string, platform.LocalReference) error { return nil },
	}
	queue, err := newTransfers(records, accounts, runner, nil, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer queue.Close()
	if _, err := queue.enqueue(owner, transferRecord{TransferJob: job, Upload: &request}); err != nil {
		t.Fatal(err)
	}
	got := waitTransferState(t, queue, id, TransferFailed)
	if len(got.Items) != 1 || !got.Items[0].CanRebind {
		t.Fatalf("upload result did not expose file action: %+v", got)
	}
	if err := queue.RebindUploadSource(t.Context(), id, relative, platform.LocalReference{Path: filepath.Join(t.TempDir(), "new.txt")}); err != nil {
		t.Fatal(err)
	}
	waitTransferState(t, queue, id, TransferCompleted)
	for range 2 {
		req := <-seen
		if req.ID != request.ID || req.Target != request.Target || req.Sources[0].Path != request.Sources[0].Path {
			t.Fatalf("rescheduled a different request: %+v", req)
		}
	}
}
