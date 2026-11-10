package app

import (
	"context"
	"errors"
	"io/fs"
)

// RetryShareCleanup retries only the owned staging directory of a completed,
// verified download. It preserves the task and never repeats transfer or download.
func (t *Transfers) RetryShareCleanup(ctx context.Context, id string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	worker, err := t.beginShareCleanup(id, cancel)
	if err != nil {
		return err
	}
	defer func() {
		t.mu.Lock()
		delete(t.active, id)
		t.scheduleLocked()
		t.mu.Unlock()
		t.changed()
		t.wg.Done()
	}()
	t.changed()
	err = t.checkAccount(worker)
	if err == nil {
		err = worker.job.Download.Cleanup.Cleanup(ctx, worker.session)
	}
	if ctx.Err() == nil {
		t.accounts.ExpireSession(worker.job.Provider, worker.session, err)
	}
	if ctx.Err() != nil {
		err = errors.Join(err, ctx.Err())
	} else if changed := t.checkAccount(worker); changed != nil {
		err = errors.Join(err, changed)
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	index := t.find(id)
	job := t.jobs[index]
	if err == nil {
		download := *job.Download
		download.Cleanup = nil
		job.Download, job.Warning = &download, ""
	} else {
		job.Warning = "没有删除网盘中的转存文件：" + err.Error()
	}
	return errors.Join(err, t.replaceLocked(index, job))
}

// beginShareCleanup shares the worker stop/removal barrier with ordinary jobs.
// Its completed state is retained while the cloud-only cleanup is in progress.
func (t *Transfers) beginShareCleanup(id string, cancel context.CancelFunc) (*transferWorker, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return nil, fs.ErrClosed
	}
	index := t.find(id)
	if index < 0 {
		return nil, errTransferMissing
	}
	job := t.jobs[index]
	if t.suspended || t.applyProxy != nil || t.active[id] != nil || t.removingDownloads[id] ||
		!canRetryShareCleanup(job) {
		return nil, errors.New("当前任务无法重试清理转存文件。")
	}
	session := t.accounts.Session(job.Provider)
	if session.State != LoggedIn || session.ID != job.AccountID {
		return nil, ErrShareAccount
	}
	worker := &transferWorker{job: job, session: session, cancel: cancel, cleanupOnly: true, done: job.Done, total: job.Total}
	t.active[id] = worker
	t.wg.Add(1)
	return worker, nil
}

func canRetryShareCleanup(job transferRecord) bool {
	req := job.Download
	if job.Direction != TransferDownload || job.State != TransferCompleted || job.RemovalPending ||
		req == nil || !req.CleanupAfterShare || req.Cleanup == nil ||
		req.Cleanup.Provider != job.Provider || req.Cleanup.AccountID != job.AccountID ||
		len(req.Plan) == 0 || len(req.Plan) != len(job.Items) {
		return false
	}
	files := 0
	for i, item := range job.Items {
		planned := req.Plan[i]
		if item.Remote != planned.Entry.Ref || item.RelativePath != planned.RelativePath ||
			item.Directory != planned.Entry.IsDirectory || item.Size != planned.Entry.Size || !item.Complete || item.Trashed {
			return false
		}
		if item.Directory {
			continue
		}
		files++
		if !item.Verified || planned.ExpectedMD5 == "" && planned.ExpectedSHA256 == "" ||
			planned.ExpectedMD5 != "" && usableMD5(planned.ExpectedMD5) == "" || !validArchiveSHA256(planned.ExpectedSHA256) {
			return false
		}
	}
	return files > 0
}
