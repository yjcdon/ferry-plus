package app

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/core"
)

type reconcileTestRunner struct {
	uploadTestWorker
	pending   func(string) (bool, error)
	reconcile func(context.Context, core.UploadRequest, core.UploadProviders) ([]core.CanceledUploadItem, error)
}

func (r reconcileTestRunner) HasPendingUpload(id string) (bool, error) {
	return r.pending(id)
}

func (r reconcileTestRunner) ReconcileCanceledUpload(ctx context.Context, req core.UploadRequest, providers core.UploadProviders) ([]core.CanceledUploadItem, error) {
	return r.reconcile(ctx, req, providers)
}

func TestCanceledUploadReconcilesBeforeRemovalWithoutResumingWorker(t *testing.T) {
	accounts := NewAccounts(nil, nil)
	owner := transferTestSession(accounts, "owner")
	records := &transferTestRecords{}
	const id = "upload-to-cancel"
	started := make(chan string, 1)
	var runs, checks atomic.Int32
	var pending atomic.Bool
	runner := reconcileTestRunner{
		uploadTestWorker: func(ctx context.Context, req core.UploadRequest, _ core.UploadProviders, progress func(core.UploadProgress)) (core.UploadResult, error) {
			runs.Add(1)
			// Baidu precreate or Quark hash can have an unresolved result
			// even while the UI still says the upload is preparing.
			pending.Store(true)
			progress(core.UploadProgress{RelativePath: "sample.txt", Phase: "preparing"})
			started <- req.ID
			<-ctx.Done()
			return core.UploadResult{}, ctx.Err()
		},
		pending: func(id string) (bool, error) { return pending.Load(), nil },
		reconcile: func(_ context.Context, req core.UploadRequest, providers core.UploadProviders) ([]core.CanceledUploadItem, error) {
			if req.ID != id || req.Target.AccountID != owner.ID || providers.AccountID != owner.ID {
				return nil, errors.New("wrong frozen account or task")
			}
			if checks.Add(1) == 1 {
				return nil, core.ErrUploadUnconfirmed
			}
			pending.Store(false)
			return []core.CanceledUploadItem{{RelativePath: "sample.txt", Path: "/sample.txt", FSID: 42, Size: 1}}, nil
		},
	}
	newQueue := func() *Transfers {
		queue, err := newTransfers(records, accounts, runner, nil, TransferConfig{}, nil)
		if err != nil {
			t.Fatal(err)
		}
		return queue
	}
	queue := newQueue()
	defer queue.Close()
	job := newTransferJob(Baidu, owner, "sample.txt", TransferUpload)
	job.ID = id
	req := core.UploadRequest{ID: id, Target: core.UploadTarget{Provider: string(Baidu), AccountID: owner.ID, Path: "/"}}
	if _, err := queue.enqueue(owner, transferRecord{TransferJob: job, Upload: &req}); err != nil {
		t.Fatal(err)
	}
	takeTransferID(t, started)
	if err := queue.Cancel(id); err != nil {
		t.Fatal(err)
	}
	if got := waitTransferState(t, queue, id, TransferNeedsCheck); !got.CancellationRequested {
		t.Fatalf("cancel intent was lost: %+v", got)
	}
	queue.Close()

	restored := newQueue()
	defer restored.Close()
	if err := restored.Remove(id); err == nil {
		t.Fatal("removed an unresolved canceled upload")
	}
	if err := restored.Resume(id); err == nil {
		t.Fatal("resumed a canceled upload")
	}
	if err := restored.ReconcileCanceledUpload(t.Context(), id); !errors.Is(err, core.ErrUploadUnconfirmed) {
		t.Fatalf("first check = %v", err)
	}
	waitTransferState(t, restored, id, TransferNeedsCheck)
	if err := restored.ReconcileCanceledUpload(t.Context(), id); err != nil {
		t.Fatal(err)
	}
	got := waitTransferState(t, restored, id, TransferCanceled)
	if runs.Load() != 1 || len(got.Items) != 1 || got.Items[0].Remote.ID != "42" || got.Items[0].Verified || got.Items[0].Complete {
		t.Fatalf("unexpected canceled outcome = %+v, upload runs = %d", got, runs.Load())
	}
	if err := restored.Remove(id); err != nil || len(restored.Snapshot()) != 0 {
		t.Fatalf("resolved record could not be removed: %v", err)
	}
}
