package core

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
)

var errMissingUploadReceipt = errors.New("缺少可核对的远端回执，已保留任务记录")

// CanceledUploadItem is a cloud object already confirmed for a canceled job.
// Complete reflects an earlier completed transfer, not a metadata lookup.
type CanceledUploadItem struct {
	RelativePath string
	Path         string
	FSID         int64
	FID          string
	Size         int64
	Directory    bool
	Complete     bool
}

// HasPendingUpload reports persisted remote intents after the worker stops.
func (u *Uploader) HasPendingUpload(id string) (bool, error) {
	release, err := u.claim(id)
	if err != nil {
		return false, err
	}
	defer release()
	key := uploadJobKey(id)
	manifest, err := u.savedUploadManifest(key)
	if err != nil {
		return false, err
	}
	for _, entry := range manifest.Entries {
		state, err := u.savedUploadItem(key, entry.Relative)
		if err != nil {
			return false, err
		}
		if state.Intent != "" {
			return true, nil
		}
	}
	return false, nil
}

// ReconcileCanceledUpload only inspects existing receipts and exact provider
// identities. It never sends or finishes an upload, creates directories, or
// recycles any object.
func (u *Uploader) ReconcileCanceledUpload(ctx context.Context, req UploadRequest, providers UploadProviders) ([]CanceledUploadItem, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	release, err := u.claim(req.ID)
	if err != nil {
		return nil, err
	}
	defer release()
	key := uploadJobKey(req.ID)
	manifest, err := u.savedUploadManifest(key)
	if err != nil {
		return nil, err
	}
	if len(manifest.Entries) == 0 {
		return nil, nil
	}
	if manifest.Target != req.Target || req.Target.AccountID == "" || req.Target.AccountID != providers.AccountID {
		return nil, errors.New("上传核对任务与原账号或目标不一致")
	}
	run := uploadRun{req: req, providers: providers}
	var items []CanceledUploadItem
	var unresolved error
	for _, entry := range manifest.Entries {
		if err := ctx.Err(); err != nil {
			return items, err
		}
		state, err := u.savedUploadItem(key, entry.Relative)
		if err != nil {
			return items, err
		}
		if state.Intent != "" {
			if err := reconcileCanceledItem(ctx, &run, &state); err != nil {
				if unresolved == nil {
					unresolved = fmt.Errorf("%s: %w", entry.Relative, errors.Join(ErrUploadUnconfirmed, err))
				}
				continue
			}
			if err := u.records.Write(uploadItemKey(key, entry.Relative), state); err != nil {
				return items, err
			}
		}
		if state.Remote.identified() {
			items = append(items, CanceledUploadItem{RelativePath: entry.Relative, Path: state.Remote.Path,
				FSID: state.Remote.FSID, FID: state.Remote.FID, Size: entry.Size, Directory: entry.Directory, Complete: state.Complete})
		}
	}
	if err := ctx.Err(); err != nil {
		return items, err
	}
	return items, unresolved
}

func reconcileCanceledItem(ctx context.Context, run *uploadRun, state *uploadItemState) error {
	if run.req.Target.Provider != "quark" || run.providers.Quark == nil || state.Quark == nil {
		return errMissingUploadReceipt
	}
	switch state.Intent {
	case "quark-merged":
		// The OSS merge was acknowledged, and the drive finish request was
		// never sent. Cancel abandons publication without deleting anything.
	case "quark-hash", "quark-merge", "quark-finish":
		remote, err := run.checkQuarkObject(ctx, *state.Quark)
		if err != nil {
			if !errors.Is(err, ErrUploadReadback) {
				return err
			}
			// An exact FID with a conflicting type or size is a definite
			// rejection. It does not become a confirmed upload result.
		} else {
			state.Remote, state.Name = remote, remote.Name
		}
	default:
		return errMissingUploadReceipt
	}
	state.Intent = ""
	return nil
}

func (u *Uploader) savedUploadManifest(key string) (uploadManifest, error) {
	var manifest uploadManifest
	err := u.records.Read(key, &manifest)
	if errors.Is(err, fs.ErrNotExist) {
		err = nil
	}
	return manifest, err
}

func (u *Uploader) savedUploadItem(key, relative string) (uploadItemState, error) {
	var state uploadItemState
	err := u.records.Read(uploadItemKey(key, relative), &state)
	if errors.Is(err, fs.ErrNotExist) {
		err = nil
	}
	return state, err
}
