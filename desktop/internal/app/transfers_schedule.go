package app

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"slices"
	"time"

	"github.com/yjcdon/ferry-drive/desktop/internal/core"
)

type transferWorker struct {
	job         transferRecord
	session     AccountSession
	config      TransferConfig
	cancel      context.CancelFunc
	stop        string
	done, total int64
	speed       int64
	started     time.Time
	startBytes  int64
	notifiedAt  time.Time
}

func (t *Transfers) Pause(id string) error {
	return t.act(id, func(job *transferRecord, worker *transferWorker) error {
		if job.State != TransferQueued && job.State != TransferRunning {
			return errors.New("当前任务无法暂停。")
		}
		job.State = TransferPaused
		return nil
	}, "pause")
}

func (t *Transfers) Resume(id string) error {
	return t.act(id, func(job *transferRecord, worker *transferWorker) error {
		if job.State != TransferPaused && job.State != TransferFailed && job.State != TransferNeedsCheck {
			return errors.New("当前任务无法继续。")
		}
		if job.CancellationRequested {
			return errors.New("任务已请求取消，请先核对尚未确认的网盘结果。")
		}
		if !t.hasAccount(job.TransferJob) {
			return errors.New("请重新登录此任务所属的账号。")
		}
		job.State, job.Stage, job.Error, job.DuplicateOf = TransferQueued, "", "", ""
		return nil
	}, "")
}

func (t *Transfers) RetryFailed(id string) error { return t.Resume(id) }

// Remove clears a terminal row and leaves its local and remote files intact.
func (t *Transfers) Remove(id string) error {
	t.mu.Lock()
	defer func() {
		t.mu.Unlock()
		t.changed()
	}()
	if t.closed {
		return fs.ErrClosed
	}
	index := t.find(id)
	if index < 0 {
		return errTransferMissing
	}
	job := t.jobs[index]
	if t.active[id] != nil || t.rebindings[id].cancel != nil ||
		job.State != TransferCompleted && job.State != TransferCanceled && job.State != TransferFailed ||
		job.CancellationRequested && job.State == TransferFailed {
		return errors.New("当前任务无法清除记录。")
	}
	if job.State == TransferFailed && job.Download != nil && job.Download.Share && job.Download.Plan == nil {
		if err := t.shares.DiscardStage(id); err != nil {
			return err
		}
	}
	next := slices.Delete(slices.Clone(t.jobs), index, index+1)
	if err := t.records.Write(transferRecordName, next); err != nil {
		return err
	}
	t.jobs = next
	return nil
}

func (t *Transfers) Cancel(id string) error {
	return t.act(id, func(job *transferRecord, worker *transferWorker) error {
		if job.Direction != TransferUpload || job.State != TransferQueued && job.State != TransferRunning && job.State != TransferPaused {
			return errors.New("当前任务无法取消。")
		}
		job.State = TransferCanceled
		job.CancellationRequested = true
		job.DuplicateOf = ""
		if job.Stage == "committing" {
			job.State = TransferNeedsCheck
			job.Error = core.ErrUploadUnconfirmed.Error()
		}
		return nil
	}, "cancel")
}

func (t *Transfers) Prioritize(id string) error {
	return t.act(id, func(job *transferRecord, worker *transferWorker) error {
		if job.Direction != TransferUpload || job.State != TransferQueued || worker != nil {
			return errors.New("只能优先安排等待中的上传。")
		}
		job.Priority = time.Now().UnixNano()
		return nil
	}, "")
}

// AccountsChanged is called after a login, logout or authentication expiry.
// It revokes old workers and wakes queued tasks for a matching verified account.
func (t *Transfers) AccountsChanged() {
	t.mu.Lock()
	for _, worker := range t.active {
		current := t.accounts.Session(worker.job.Provider)
		if !sameDirectorySession(worker.session, current) && worker.stop == "" {
			worker.stop = "account"
			worker.cancel()
		}
	}
	for _, binding := range t.rebindings {
		if !sameDirectorySession(binding.session, t.accounts.Session(binding.provider)) {
			binding.cancel()
		}
	}
	t.scheduleLocked()
	t.mu.Unlock()
	t.changed()
}

// ChangeProxy stops active transfers and applies only the most recently
// requested transport after their checkpoints are saved. apply must not
// call the queue or block on the UI thread.
func (t *Transfers) ChangeProxy(apply func()) {
	if apply == nil {
		return
	}
	t.mu.Lock()
	if !t.closed {
		t.applyProxy = apply
		for _, worker := range t.active {
			if worker.stop == "" {
				worker.stop = "proxy"
				worker.cancel()
			}
		}
		t.scheduleLocked()
	}
	t.mu.Unlock()
	t.changed()
}

// Suspend stops scheduling and lets current workers save their checkpoints.
// System sleep leaves manual pause and cancellation intent intact.
func (t *Transfers) Suspend() {
	t.mu.Lock()
	t.suspended = true
	for _, worker := range t.active {
		if worker.stop == "" {
			worker.stop = "suspend"
			worker.cancel()
		}
	}
	for _, binding := range t.rebindings {
		binding.cancel()
	}
	t.mu.Unlock()
	t.changed()
}

// Wake restarts eligible work only after each earlier worker has exited.
func (t *Transfers) Wake() {
	t.mu.Lock()
	t.suspended = false
	t.scheduleLocked()
	t.mu.Unlock()
	t.changed()
}

// Close stops new work and waits for every active worker to save its receipts.
func (t *Transfers) Close() {
	t.mu.Lock()
	t.closed = true
	for _, worker := range t.active {
		if worker.stop == "" {
			worker.stop = "close"
			worker.cancel()
		}
	}
	for _, binding := range t.rebindings {
		binding.cancel()
	}
	t.mu.Unlock()
	t.wg.Wait()
}

func (t *Transfers) act(id string, apply func(*transferRecord, *transferWorker) error, stop string) error {
	t.mu.Lock()
	defer func() {
		t.mu.Unlock()
		t.changed()
	}()
	if t.closed {
		return fs.ErrClosed
	}
	index := t.find(id)
	if index < 0 {
		return errTransferMissing
	}
	job, worker := t.jobs[index], t.active[id]
	if t.rebindings[id].cancel != nil {
		return errors.New("正在检查所选源文件。")
	}
	if err := apply(&job, worker); err != nil {
		return err
	}
	if err := t.replaceLocked(index, job); err != nil {
		return err
	}
	if stop != "" && worker != nil {
		worker.stop = stop
		worker.cancel()
	}
	t.scheduleLocked()
	return nil
}

func (t *Transfers) find(id string) int {
	for i, job := range t.jobs {
		if job.ID == id {
			return i
		}
	}
	return -1
}

func (t *Transfers) replaceLocked(index int, next transferRecord) error {
	before := t.jobs[index]
	t.jobs[index] = next
	if err := t.records.Write(transferRecordName, t.jobs); err != nil {
		t.jobs[index] = before
		return err
	}
	return nil
}

func (t *Transfers) scheduleLocked() {
	if t.closed {
		return
	}
	if t.applyProxy != nil {
		if len(t.active) > 0 {
			return
		}
		t.applyProxy()
		t.applyProxy = nil
	}
	if t.suspended {
		return
	}
	running := map[TransferDirection]int{}
	for _, worker := range t.active {
		running[worker.job.Direction]++
	}
	for _, direction := range []TransferDirection{TransferDownload, TransferUpload} {
		limit := t.config.DownloadFiles
		if direction == TransferUpload {
			limit = t.config.UploadJobs
		}
		for running[direction] < limit {
			index, session := t.nextLocked(direction)
			if index == -1 {
				break
			}
			job := t.jobs[index]
			job.State, job.Stage = TransferRunning, "preparing"
			if err := t.replaceLocked(index, job); err != nil {
				t.jobs[index].State = TransferFailed
				t.jobs[index].Error = fmt.Sprintf("保存传输状态: %v", err)
				break
			}
			ctx, cancel := context.WithCancel(context.Background())
			worker := &transferWorker{
				job: job, session: session, config: t.config, cancel: cancel,
				done: job.Done, total: job.Total, started: time.Now(), startBytes: job.Done,
			}
			t.active[job.ID] = worker
			running[direction]++
			t.wg.Go(func() { t.run(ctx, worker) })
		}
	}
}

func (t *Transfers) nextLocked(direction TransferDirection) (int, AccountSession) {
	selected := -1
	var selectedSession AccountSession
	for i, job := range t.jobs {
		if job.Direction != direction || job.State != TransferQueued || t.active[job.ID] != nil {
			continue
		}
		session := t.accounts.Session(job.Provider)
		if session.State != LoggedIn || session.ID != job.AccountID {
			continue
		}
		if selected == -1 || job.Priority > t.jobs[selected].Priority ||
			job.Priority == t.jobs[selected].Priority && job.CreatedAt.Before(t.jobs[selected].CreatedAt) {
			selected, selectedSession = i, session
		}
	}
	return selected, selectedSession
}

func (t *Transfers) checkAccount(worker *transferWorker) error {
	current := t.accounts.Session(worker.job.Provider)
	if current.State != LoggedIn || !sameDirectorySession(worker.session, current) {
		return ErrDirectorySessionChanged
	}
	return nil
}

func (t *Transfers) report(worker *transferWorker, stage string, done, total int64) {
	t.mu.Lock()
	index := t.find(worker.job.ID)
	job := &t.jobs[index]
	stageChanged := job.Stage != stage
	job.Stage = stage
	worker.done, worker.total = done, total
	if elapsed := time.Since(worker.started).Seconds(); elapsed >= 0.5 {
		worker.speed = int64(float64(max(0, done-worker.startBytes)) / elapsed)
	}
	notify := stageChanged || time.Since(worker.notifiedAt) >= 500*time.Millisecond
	if notify {
		worker.notifiedAt = time.Now()
	}
	t.mu.Unlock()
	if notify {
		t.changed()
	}
}

func (t *Transfers) run(ctx context.Context, worker *transferWorker) {
	defer worker.cancel()
	var items []TransferItem
	var warning string
	err := ctx.Err()
	if err == nil {
		err = t.checkAccount(worker)
	}
	if err == nil {
		func() {
			if t.beginActivity != nil {
				release, activityErr := t.beginActivity()
				if activityErr != nil {
					log.Printf("保持传输期间唤醒: %v", activityErr)
				} else {
					defer release()
				}
			}
			if worker.job.Direction == TransferUpload {
				items, err = t.runUpload(ctx, worker)
			} else {
				warning, err = t.runDownload(ctx, worker)
			}
		}()
	}

	t.mu.Lock()
	index := t.find(worker.job.ID)
	next := t.jobs[index]
	if items != nil {
		next.Items = mergeTransferItems(next.Items, items)
		next.Done, next.Total = completedTotals(next.Items)
	}
	if warning != "" {
		next.Warning = warning
	}
	switch {
	case next.State == TransferNeedsCheck && worker.stop == "cancel" && err == nil:
		next.State, next.Error = TransferCanceled, ""
	case next.State == TransferNeedsCheck:
	case worker.stop == "cancel" && errors.Is(err, core.ErrUploadUnconfirmed):
		next.State, next.Error = TransferNeedsCheck, err.Error()
	case worker.stop == "cancel":
	case errors.Is(err, errDuplicateUpload):
		// The decision is already durable. A fast confirmation may have
		// queued the task again while this worker was releasing its claim.
	case err == nil:
		next.State, next.Error = TransferCompleted, ""
	case worker.stop == "pause":
		// The state may already be queued if the user clicked Continue.
	case worker.stop == "account" || worker.stop == "close" || worker.stop == "suspend" || worker.stop == "proxy" ||
		errors.Is(err, ErrDirectorySessionChanged) || t.checkAccount(worker) != nil:
		next.State, next.Error = TransferQueued, ""
	case errors.Is(err, core.ErrUploadUnconfirmed), errors.Is(err, ErrShareTransferUnconfirmed):
		next.State, next.Error = TransferNeedsCheck, err.Error()
	default:
		next.State, next.Error = TransferFailed, err.Error()
	}
	if err := t.replaceLocked(index, next); err != nil {
		t.jobs[index].State = TransferFailed
		t.jobs[index].Error = fmt.Sprintf("保存传输结果: %v", err)
	}
	delete(t.active, worker.job.ID)
	t.scheduleLocked()
	t.mu.Unlock()
	t.changed()
}
