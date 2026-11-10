package app

import (
	"context"
	"errors"
	"io/fs"
	"log"
	"path/filepath"
	"slices"

	"github.com/yjcdon/ferry-drive/desktop/internal/core"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

type uploadSourceRebinder interface {
	RebindSource(context.Context, string, string, platform.LocalReference) error
}

type uploadCheck struct {
	provider     Provider
	session      AccountSession
	relativePath string
	cancel       context.CancelFunc
}

// RebindUploadSource checks the replacement against the durable original.
// A failed task returns to the queue on success; a manual pause is preserved.
func (t *Transfers) RebindUploadSource(ctx context.Context, id, relativePath string, replacement platform.LocalReference) error {
	rebinder, ok := t.upload.(uploadSourceRebinder)
	if !ok || !filepath.IsAbs(replacement.Path) {
		return core.ErrUploadSourceNotRebindable
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	binding, err := t.beginUploadRebinding(id, relativePath, cancel)
	if err != nil {
		return err
	}
	defer t.wg.Done()
	t.changed()
	replacement.Bookmark = slices.Clone(replacement.Bookmark)

	if t.beginActivity != nil {
		release, activityErr := t.beginActivity()
		if activityErr != nil {
			log.Printf("保持源文件校验期间唤醒: %v", activityErr)
		} else {
			defer release()
		}
	}
	err = rebinder.RebindSource(ctx, id, relativePath, replacement)

	t.mu.Lock()
	defer t.finishUploadCheckLocked(id)
	if err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if !sameDirectorySession(binding.session, t.accounts.Session(binding.provider)) {
		return ErrDirectorySessionChanged
	}

	index := t.find(id)
	next := t.jobs[index]
	next.Items = slices.Clone(next.Items)
	for i := range next.Items {
		item := &next.Items[i]
		if item.RelativePath == relativePath {
			item.Error, item.CanRebind = "", false
			break
		}
	}
	next.Error, next.Stage = "", ""
	if next.State == TransferFailed {
		next.State = TransferQueued
	}
	return t.replaceLocked(index, next)
}

func (t *Transfers) beginUploadRebinding(id, relativePath string, cancel context.CancelFunc) (uploadCheck, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return uploadCheck{}, fs.ErrClosed
	}
	index := t.find(id)
	if index < 0 {
		return uploadCheck{}, errTransferMissing
	}
	job := t.jobs[index]
	if t.suspended || t.active[id] != nil || t.uploadChecks[id].cancel != nil {
		return uploadCheck{}, errors.New("请等待当前传输停止后再选择源文件。")
	}
	if job.Direction != TransferUpload || job.CancellationRequested ||
		job.State != TransferFailed && job.State != TransferPaused ||
		!slices.ContainsFunc(job.Items, func(item TransferItem) bool {
			return item.RelativePath == relativePath && item.CanRebind && item.Error != ""
		}) {
		return uploadCheck{}, core.ErrUploadSourceNotRebindable
	}
	return t.beginUploadCheckLocked(job, relativePath, cancel)
}

func (t *Transfers) beginUploadCheckLocked(job transferRecord, relativePath string, cancel context.CancelFunc) (uploadCheck, error) {
	session := t.accounts.Session(job.Provider)
	if session.State != LoggedIn || session.ID != job.AccountID {
		return uploadCheck{}, ErrDirectorySessionChanged
	}
	check := uploadCheck{provider: job.Provider, session: session, relativePath: relativePath, cancel: cancel}
	t.uploadChecks[job.ID] = check
	t.wg.Add(1)
	return check, nil
}

func (t *Transfers) finishUploadCheckLocked(id string) {
	delete(t.uploadChecks, id)
	t.scheduleLocked()
	t.mu.Unlock()
	t.changed()
}
