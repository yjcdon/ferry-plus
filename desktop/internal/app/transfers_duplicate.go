package app

import (
	"context"
	"errors"
	"slices"
)

var errDuplicateUpload = errors.New("已有相同内容的上传")

func matchingUploadTarget(a, b transferRecord) bool {
	return a.Upload != nil && b.Upload != nil && a.Upload.Target == b.Upload.Target
}

func eligibleDuplicate(candidate transferRecord, wasActive bool) bool {
	if candidate.CancellationRequested || candidate.DuplicateOf != "" ||
		slices.ContainsFunc(candidate.Items, func(item TransferItem) bool { return item.Error != "" }) {
		return false
	}
	switch candidate.State {
	case TransferQueued, TransferWaitingAccount, TransferRunning, TransferPaused:
		return true
	case TransferCompleted:
		return wasActive
	default:
		return false
	}
}

// checkUploadDuplicate reserves the first complete signature under the same
// lock that stores duplicate decisions. The engine waits before any cloud write.
func (t *Transfers) checkUploadDuplicate(ctx context.Context, worker *transferWorker, signature string, canPause bool) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	if t.closed || t.active[worker.job.ID] != worker || worker.stop != "" {
		return context.Canceled
	}
	if err := t.checkAccount(worker); err != nil {
		return err
	}
	index := t.find(worker.job.ID)
	if index < 0 {
		return errTransferMissing
	}
	job := t.jobs[index]
	if job.DuplicateOf != "" {
		return errDuplicateUpload
	}
	if signature == "" {
		return nil
	}
	if job.UploadSignature != "" {
		if job.UploadSignature != signature {
			return errors.New("上传内容签名与已保存的任务不一致。")
		}
		return nil
	}

	job.UploadSignature = signature
	if canPause {
		var original transferRecord
		for _, candidate := range t.jobs {
			if candidate.ID != job.ID && candidate.UploadSignature == signature && matchingUploadTarget(candidate, job) &&
				eligibleDuplicate(candidate, slices.Contains(job.DuplicateCandidates, candidate.ID)) &&
				(original.ID == "" || candidate.CreatedAt.Before(original.CreatedAt)) {
				original = candidate
			}
		}
		if original.ID != "" {
			job.DuplicateOf = original.ID
			job.State, job.Stage, job.Error = TransferPaused, "", ""
		}
	}
	job.DuplicateCandidates = nil
	if err := t.replaceLocked(index, job); err != nil {
		return err
	}
	if job.DuplicateOf != "" {
		return errDuplicateUpload
	}
	return nil
}
