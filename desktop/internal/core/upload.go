// Package core coordinates provider-neutral transfer operations.
package core

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"path"
	"slices"
	"strings"
	"sync"

	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
	"github.com/yjcdon/ferry-drive/desktop/internal/quark"
	"github.com/yjcdon/ferry-drive/desktop/internal/store"
)

var (
	ErrUploadSourceChanged = errors.New("上传源已变更，请重新选择原始文件")
	ErrUploadUnconfirmed   = errors.New("上传请求的远端结果尚未确认，请先核对")
	ErrUploadReadback      = errors.New("上传后的文件内容与本地原件不一致")
)

const (
	UploadKeepBoth = "keepBoth" // 保留两份
	UploadSkip     = "skip"     // 跳过同名文件
)

// UploadTarget freezes a destination account and directory. Baidu uses Path and
// FSID (the root is / and 0). Quark uses FID (the root is 0).
type UploadTarget struct {
	Provider, AccountID string
	Path                string
	FSID                int64
	FID                 string
}

type UploadRequest struct {
	ID                     string
	Target                 UploadTarget
	Sources                []platform.LocalReference
	ConflictPolicy         string
	ParallelParts          int
	BytesPerSecond         int64
	WaitUploadBudget       func(context.Context, int) error `json:"-"`
	ReadbackBytesPerSecond int64
	// BeforeRemote receives the durable batch signature before any new cloud
	// writes. An empty signature means an original content basis is missing.
	// Returning an error stops the worker before those writes.
	BeforeRemote func(signature string, canPause bool) error `json:"-"`
}

// UploadProviders holds the current account's protocol client. The caller
// revokes it and cancels Run when the account changes or signs out.
type UploadProviders struct {
	Baidu     *baidu.Client
	Quark     *quark.Client
	AccountID string
}

type UploadProgress struct {
	RelativePath string
	Phase        string // preparing, uploading, committing, verifying, completed, skipped, failed
	Done, Total  int64
}

type UploadItemResult struct {
	RelativePath string
	RemoteName   string
	Path         string
	FSID         int64
	FID          string
	Size         int64
	Directory    bool
	Skipped      bool
	CanRebind    bool
	Error        string
}

type UploadResult struct {
	Items []UploadItemResult
}

type uploadStore interface {
	Read(string, any) error
	Write(string, any) error
	ReadCredential(string) ([]byte, error)
	WriteCredential(string, []byte) error
	RemoveCredential(string) error
}

type Uploader struct {
	records uploadStore
	client  *http.Client
	mu      sync.Mutex
	active  map[string]bool
}

func NewUploader(records *store.Store, client *http.Client) *Uploader {
	return newUploader(records, client)
}

func newUploader(records uploadStore, client *http.Client) *Uploader {
	return &Uploader{records: records, client: uploadReadbackClient(client), active: make(map[string]bool)}
}

type uploadManifest struct {
	Target        UploadTarget
	Policy        string
	Sources       []platform.LocalReference
	Entries       []uploadLocalItem
	Signature     string `json:",omitempty"`
	RemoteStarted bool   `json:",omitempty"`
}

type uploadItemState struct {
	Name            string
	Remote          uploadRemoteItem
	Skipped         bool
	Complete        bool
	Intent          string
	Fingerprint     uploadFingerprint
	Baidu           *baidu.UploadSession
	BaiduParts      []baidu.UploadPartReceipt
	BaiduRapidTried bool
	Quark           *quark.UploadSession
	QuarkParts      []quark.UploadPartReceipt
	QuarkHashed     bool
}

type uploadRun struct {
	req       UploadRequest
	providers UploadProviders
	records   uploadStore
	client    *http.Client
	progress  func(UploadProgress)
	upload    uploadPacer
	readback  uploadPacer
}

type uploadRemoteItem struct {
	Name      string
	Path      string
	FSID      int64
	FID       string
	Size      int64
	Directory bool
}

func (i uploadRemoteItem) identified() bool { return i.FSID > 0 || i.FID != "" }

// Run scans selected roots once and resumes per-object durable checkpoints.
// Cancel the context and await return before starting another run of this job.
func (u *Uploader) Run(ctx context.Context, req UploadRequest, providers UploadProviders, progress func(UploadProgress)) (UploadResult, error) {
	if req.ConflictPolicy == "" {
		req.ConflictPolicy = UploadKeepBoth
	}
	if req.ParallelParts == 0 {
		req.ParallelParts = 1
	}
	if req.ID == "" || len(req.Sources) == 0 || req.Target.AccountID == "" ||
		req.Target.AccountID != providers.AccountID ||
		req.ConflictPolicy != UploadKeepBoth && req.ConflictPolicy != UploadSkip ||
		req.ParallelParts < 1 || req.ParallelParts > 4 || req.BytesPerSecond < 0 || req.ReadbackBytesPerSecond < 0 {
		return UploadResult{}, errors.New("上传任务参数或账号无效")
	}
	switch req.Target.Provider {
	case "baidu":
		if providers.Baidu == nil || !strings.HasPrefix(req.Target.Path, "/") || path.Clean(req.Target.Path) != req.Target.Path ||
			req.Target.Path == "/" && req.Target.FSID != 0 || req.Target.Path != "/" && req.Target.FSID <= 0 {
			return UploadResult{}, errors.New("百度上传目标无效")
		}
	case "quark":
		if providers.Quark == nil || req.Target.FID == "" {
			return UploadResult{}, errors.New("夸克上传目标无效")
		}
	default:
		return UploadResult{}, errors.New("上传任务的网盘无效")
	}
	if err := ctx.Err(); err != nil {
		return UploadResult{}, err
	}
	release, err := u.claim(req.ID)
	if err != nil {
		return UploadResult{}, err
	}
	defer release()

	name := uploadJobKey(req.ID)
	var manifest uploadManifest
	err = u.records.Read(name, &manifest)
	if errors.Is(err, fs.ErrNotExist) {
		sources, entries, err := scanUpload(ctx, req.Sources)
		if err != nil {
			return UploadResult{}, err
		}
		manifest = uploadManifest{Target: req.Target, Policy: req.ConflictPolicy, Sources: sources, Entries: entries}
		if err := u.records.Write(name, manifest); err != nil {
			return UploadResult{}, err
		}
	} else if err != nil {
		return UploadResult{}, err
	} else if manifest.Target != req.Target || manifest.Policy != req.ConflictPolicy ||
		!slices.EqualFunc(manifest.Sources, req.Sources, func(a, b platform.LocalReference) bool { return a.Path == b.Path }) {
		return UploadResult{}, errors.New("上传恢复记录与原账号、目标或选项不一致")
	}
	run := uploadRun{req: req, providers: providers, records: u.records, client: u.client, progress: progress,
		upload: uploadPacer{rate: req.BytesPerSecond, shared: req.WaitUploadBudget}, readback: uploadPacer{rate: req.ReadbackBytesPerSecond}}
	failed, err := run.prepareContent(ctx, &manifest, name)
	if err != nil {
		return UploadResult{}, err
	}
	if req.BeforeRemote != nil {
		if err := req.BeforeRemote(manifest.Signature, !manifest.RemoteStarted); err != nil {
			return UploadResult{}, err
		}
	}
	if err := ctx.Err(); err != nil {
		return UploadResult{}, err
	}
	if !manifest.RemoteStarted {
		manifest.RemoteStarted = true
		if err := u.records.Write(name, manifest); err != nil {
			return UploadResult{}, err
		}
	}
	return run.run(ctx, manifest, name, failed)
}

func (u *uploadRun) run(ctx context.Context, manifest uploadManifest, name string, failed map[string]error) (UploadResult, error) {
	root := uploadRemoteItem{Directory: true, Path: u.req.Target.Path, FSID: u.req.Target.FSID, FID: u.req.Target.FID}
	directories := map[string]uploadRemoteItem{".": root}
	skipped := map[string]bool{}
	var result UploadResult
	var firstFailure error
	for _, entry := range manifest.Entries {
		if err := ctx.Err(); err != nil {
			return result, err
		}
		parentPath := path.Dir(entry.Relative)
		parent, ok := directories[parentPath]
		var state uploadItemState
		var err error
		switch {
		case skipped[parentPath]:
			state.Skipped = true
		case !ok:
			err = errors.New("上级目录尚未创建")
		case failed[entry.Relative] != nil:
			err = failed[entry.Relative]
		default:
			var source platform.LocalReference
			source, err = uploadSourceFor(manifest, &entry)
			if err != nil {
				return result, err
			}
			state, err = u.runItem(ctx, uploadItemKey(name, entry.Relative), entry, source, parent)
		}
		item := UploadItemResult{RelativePath: entry.Relative, RemoteName: state.Name, Path: state.Remote.Path, FSID: state.Remote.FSID,
			FID: state.Remote.FID, Size: entry.Size, Directory: entry.Directory, Skipped: state.Skipped}
		switch {
		case err != nil:
			item.Error = err.Error()
			item.CanRebind = canRebindUploadSource(entry, state)
			if firstFailure == nil {
				firstFailure = fmt.Errorf("%s: %w", entry.Relative, err)
			}
			u.report(entry, "failed", 0)
		case state.Skipped:
			if entry.Directory {
				skipped[entry.Relative] = true
			}
			u.report(entry, "skipped", 0)
		default:
			if entry.Directory {
				directories[entry.Relative] = state.Remote
			}
			u.report(entry, "completed", entry.Size)
		}
		result.Items = append(result.Items, item)
		if errors.Is(err, baidu.ErrLoginExpired) || errors.Is(err, quark.ErrLoginExpired) {
			return result, err
		}
	}
	if err := ctx.Err(); err != nil {
		return result, err
	}
	return result, firstFailure
}

func (u *uploadRun) runItem(ctx context.Context, key string, entry uploadLocalItem, source platform.LocalReference, parent uploadRemoteItem) (uploadItemState, error) {
	var state uploadItemState
	if err := u.records.Read(key, &state); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return state, err
	}
	save := func() error { return u.records.Write(key, state) }
	if state.Skipped {
		return state, nil
	}
	if state.Complete {
		if state.Quark != nil {
			return state, u.records.RemoveCredential(key)
		}
		return state, nil
	}
	if state.Intent != "" {
		if state.Quark == nil {
			return state, ErrUploadUnconfirmed
		}
		switch state.Intent {
		case "quark-merged":
			if err := u.finishQuark(ctx, &state, save); err != nil {
				return state, err
			}
		case "quark-hash", "quark-merge", "quark-finish":
			if err := u.confirmQuarkObject(ctx, &state, save); err != nil {
				return state, err
			}
		default:
			return state, ErrUploadUnconfirmed
		}
	}
	if state.Name == "" {
		var err error
		state.Name, state.Remote, state.Skipped, err = u.chooseName(ctx, parent, path.Base(entry.Relative), entry.Directory)
		if err != nil {
			return state, err
		}
		if state.Remote.identified() {
			state.Complete = true
		}
		if err := save(); err != nil {
			return state, err
		}
		if state.Skipped || state.Complete {
			return state, nil
		}
	}
	if entry.Directory {
		u.report(entry, "committing", 0)
		if err := u.checkParent(ctx, parent); err != nil {
			return state, err
		}
		if err := markUploadIntent(ctx, &state, "directory", save); err != nil {
			return state, err
		}
		remote, err := u.createDirectory(ctx, parent, state.Name)
		if err != nil {
			return state, err
		}
		state.Remote, state.Complete, state.Intent = remote, true, ""
		return state, save()
	}
	if !state.Remote.identified() {
		u.report(entry, "preparing", 0)
		var err error
		if u.req.Target.Provider == "baidu" {
			err = u.uploadBaidu(ctx, entry, source, parent, &state, save)
		} else {
			err = u.uploadQuark(ctx, key, entry, source, parent, &state, save)
		}
		if err != nil {
			return state, err
		}
	}
	u.report(entry, "verifying", 0)
	if err := u.verify(ctx, entry, state); err != nil {
		return state, err
	}
	state.Complete = true
	if err := save(); err != nil {
		return state, err
	}
	if state.Quark != nil {
		return state, u.records.RemoveCredential(key)
	}
	return state, nil
}

func markUploadIntent(ctx context.Context, state *uploadItemState, intent string, save func() error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	state.Intent = intent
	if err := save(); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		state.Intent = ""
		return errors.Join(err, save())
	}
	return nil
}

func (u *uploadRun) report(entry uploadLocalItem, phase string, done int64) {
	if u.progress != nil {
		u.progress(UploadProgress{RelativePath: entry.Relative, Phase: phase, Done: done, Total: entry.Size})
	}
}
