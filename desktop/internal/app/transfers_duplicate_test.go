package app

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/core"
)

func TestDuplicateUploadPausesBeforeRemoteAndRequiresExplicitContinue(t *testing.T) {
	accounts := NewAccounts(nil, nil)
	owner := transferTestSession(accounts, "owner")
	records := &transferTestRecords{}
	approved := make(chan string, 4)
	finishOriginal := make(chan struct{})
	const original, duplicate = "original", "duplicate"
	signature := strings.Repeat("a", 64)
	runner := uploadTestWorker(func(ctx context.Context, req core.UploadRequest, _ core.UploadProviders, _ func(core.UploadProgress)) (core.UploadResult, error) {
		if err := req.BeforeRemote(signature, true); err != nil {
			return core.UploadResult{}, err
		}
		approved <- req.ID
		if req.ID == original {
			select {
			case <-finishOriginal:
			case <-ctx.Done():
				return core.UploadResult{}, ctx.Err()
			}
		}
		return core.UploadResult{}, nil
	})
	newQueue := func() *Transfers {
		queue, err := newTransfers(records, accounts, runner, nil, TransferConfig{UploadJobs: 1}, nil)
		if err != nil {
			t.Fatal(err)
		}
		return queue
	}
	enqueue := func(queue *Transfers, id string) {
		t.Helper()
		job := newTransferJob(Baidu, owner, "上传样本", TransferUpload)
		job.ID = id
		_, err := queue.enqueue(owner, transferRecord{TransferJob: job, Upload: &core.UploadRequest{
			ID: id, Target: core.UploadTarget{Provider: string(Baidu), AccountID: owner.ID, Path: "/"},
		}})
		if err != nil {
			t.Fatal(err)
		}
	}
	first := newQueue()
	defer first.Close()
	enqueue(first, original)
	if id := takeTransferID(t, approved); id != original {
		t.Fatalf("first approved upload = %q", id)
	}
	enqueue(first, duplicate)
	close(finishOriginal)
	waitTransferState(t, first, original, TransferCompleted)
	job := waitTransferState(t, first, duplicate, TransferPaused)
	if job.DuplicateOf != original || job.Error != "" {
		t.Fatalf("duplicate state = %+v", job)
	}
	select {
	case id := <-approved:
		t.Fatalf("duplicate worker reached cloud writes: %s", id)
	default:
	}
	first.Close()

	restarted := newQueue()
	defer restarted.Close()
	if job := waitTransferState(t, restarted, duplicate, TransferPaused); job.DuplicateOf != original {
		t.Fatalf("duplicate decision was lost after restart: %+v", job)
	}
	if err := restarted.Resume(duplicate); err != nil {
		t.Fatal(err)
	}
	if id := takeTransferID(t, approved); id != duplicate {
		t.Fatalf("confirmed worker = %q", id)
	}
	if job := waitTransferState(t, restarted, duplicate, TransferCompleted); job.DuplicateOf != "" {
		t.Fatalf("continued job retained its duplicate marker: %+v", job)
	}

	// Completed work already present at enqueue does not block a deliberate new upload.
	enqueue(restarted, "later")
	if id := takeTransferID(t, approved); id != "later" {
		t.Fatalf("later approved worker = %q", id)
	}
	waitTransferState(t, restarted, "later", TransferCompleted)
}

func TestConcurrentUploadSignatureReservationIsScopedToExactTarget(t *testing.T) {
	accounts := NewAccounts(nil, nil)
	owner := transferTestSession(accounts, "owner")
	records := &transferTestRecords{}
	queue, err := newTransfers(records, accounts, nil, nil, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	target := core.UploadTarget{Provider: string(Baidu), AccountID: owner.ID, Path: "/folder", FSID: 20}
	other := target
	other.FSID = 21 // Same path with a different server identity.
	worker := func(id string, target core.UploadTarget) *transferWorker {
		job := newTransferJob(Baidu, owner, "上传样本", TransferUpload)
		job.ID, job.State = id, TransferRunning
		record := transferRecord{TransferJob: job, Upload: &core.UploadRequest{ID: id, Target: target}}
		w := &transferWorker{job: record, session: owner}
		queue.jobs = append(queue.jobs, record)
		queue.active[id] = w
		return w
	}
	a, b, c := worker("a", target), worker("b", target), worker("c", other)
	errorsByJob := make(chan error, 3)
	for _, candidate := range []*transferWorker{a, b, c} {
		go func() {
			errorsByJob <- queue.checkUploadDuplicate(t.Context(), candidate, strings.Repeat("b", 64), true)
		}()
	}
	paused := 0
	for range 3 {
		switch err := <-errorsByJob; {
		case errors.Is(err, errDuplicateUpload):
			paused++
		case err != nil:
			t.Fatal(err)
		}
	}
	if paused != 1 || queue.jobs[2].DuplicateOf != "" {
		t.Fatalf("paused=%d jobs=%+v", paused, queue.jobs)
	}
}
