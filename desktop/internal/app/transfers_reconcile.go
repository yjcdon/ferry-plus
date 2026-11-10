package app

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"strconv"

	"github.com/yjcdon/ferry-drive/desktop/internal/core"
)

type canceledUploadReconciler interface {
	HasPendingUpload(string) (bool, error)
	ReconcileCanceledUpload(context.Context, core.UploadRequest, core.UploadProviders) ([]core.CanceledUploadItem, error)
}

// canceledUploadState checks local durable intents after stopping a worker.
// No provider is contacted until the user requests remote reconciliation.
func (t *Transfers) canceledUploadState(id string, workerErr error) (TransferState, string) {
	if inspector, ok := t.upload.(canceledUploadReconciler); ok {
		pending, err := inspector.HasPendingUpload(id)
		switch {
		case err != nil:
			return TransferNeedsCheck, fmt.Sprintf("%s: %v", core.ErrUploadUnconfirmed, err)
		case pending:
			return TransferNeedsCheck, core.ErrUploadUnconfirmed.Error()
		}
	} else if errors.Is(workerErr, core.ErrUploadUnconfirmed) {
		return TransferNeedsCheck, workerErr.Error()
	}
	return TransferCanceled, ""
}

// ReconcileCanceledUpload queries existing remote intents without restarting
// the worker. A canceled task becomes removable only after all are resolved.
func (t *Transfers) ReconcileCanceledUpload(ctx context.Context, id string) error {
	inspector, ok := t.upload.(canceledUploadReconciler)
	if !ok {
		return core.ErrUploadUnconfirmed
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	request, check, err := t.beginCanceledUploadCheck(id, cancel)
	if err != nil {
		return err
	}
	defer t.wg.Done()
	t.changed()
	providers := core.UploadProviders{Baidu: check.session.Baidu, Quark: check.session.Quark, AccountID: check.session.ID}
	items, err := inspector.ReconcileCanceledUpload(ctx, request, providers)

	t.mu.Lock()
	defer t.finishUploadCheckLocked(id)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if !sameDirectorySession(check.session, t.accounts.Session(check.provider)) {
		return ErrDirectorySessionChanged
	}
	index := t.find(id)
	job := t.jobs[index]
	confirmedItems := make([]TransferItem, 0, len(items))
	for _, confirmed := range items {
		ref := RemoteRef{Provider: job.Provider, Path: confirmed.Path, ID: confirmed.FID}
		if confirmed.FSID != 0 {
			ref.ID = strconv.FormatInt(confirmed.FSID, 10)
		}
		confirmedItems = append(confirmedItems, TransferItem{
			RelativePath: confirmed.RelativePath, Remote: ref, Size: confirmed.Size, Directory: confirmed.Directory,
			Complete: confirmed.Complete, Verified: confirmed.Complete && !confirmed.Directory,
		})
	}
	job.Items = mergeTransferItems(job.Items, confirmedItems)
	job.Done, job.Total = completedTotals(job.Items)
	if err == nil {
		job.State, job.Error = TransferCanceled, ""
		clearCanceledUploadErrors(&job)
	} else {
		job.Error = err.Error()
	}
	job.Stage = ""
	return errors.Join(err, t.replaceLocked(index, job))
}

func clearCanceledUploadErrors(job *transferRecord) {
	for i := range job.Items {
		if !job.Items[i].Complete {
			job.Items[i].Error, job.Items[i].CanRebind = "", false
		}
	}
}

func (t *Transfers) beginCanceledUploadCheck(id string, cancel context.CancelFunc) (core.UploadRequest, uploadCheck, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return core.UploadRequest{}, uploadCheck{}, fs.ErrClosed
	}
	index := t.find(id)
	if index < 0 {
		return core.UploadRequest{}, uploadCheck{}, errTransferMissing
	}
	job := t.jobs[index]
	if t.suspended || t.active[id] != nil || t.uploadChecks[id].cancel != nil {
		return core.UploadRequest{}, uploadCheck{}, errors.New("请等待当前传输停止后再核对云端结果。")
	}
	if !job.CancellationRequested || job.State != TransferNeedsCheck || job.Upload == nil {
		return core.UploadRequest{}, uploadCheck{}, errors.New("此任务没有需要核对的取消结果。")
	}
	check, err := t.beginUploadCheckLocked(job, "", cancel)
	return *job.Upload, check, err
}
