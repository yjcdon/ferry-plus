package app

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/yjcdon/ferry-drive/desktop/internal/core"
	"github.com/yjcdon/ferry-drive/desktop/internal/download"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
	"github.com/yjcdon/ferry-drive/desktop/internal/store"
)

type TransferDirection string

const (
	TransferDownload TransferDirection = "download"
	TransferUpload   TransferDirection = "upload"
)

type TransferState string

const (
	TransferQueued         TransferState = "queued"
	TransferWaitingAccount TransferState = "waitingAccount"
	TransferRunning        TransferState = "running"
	TransferPaused         TransferState = "paused"
	TransferCompleted      TransferState = "completed"
	TransferFailed         TransferState = "failed"
	TransferCanceled       TransferState = "canceled"
	TransferNeedsCheck     TransferState = "needsCheck"
)

type TransferConfig struct {
	DownloadFiles          int
	UploadJobs             int
	BaiduConnections       int
	QuarkConnections       int
	UploadParts            int
	UploadBytesPerSecond   int64
	DownloadBytesPerSecond int64
}

// TransferJob is a snapshot of one user-visible batch.
type TransferJob struct {
	ID, Title, AccountID, AccountName string
	Provider                          Provider
	Direction                         TransferDirection
	State                             TransferState
	Stage, Error, Warning             string
	ShareURL                          string
	DuplicateOf                       string `json:",omitempty"`
	CreatedAt                         time.Time
	Done, Total                       int64
	Items                             []TransferItem
	CancellationRequested             bool
	RemovalPending                    bool   `json:",omitempty"`
	Stopping                          bool   `json:"-"`
	RebindingPath                     string `json:"-"`
	CanRetryShareCleanup              bool   `json:"-"`
	BytesPerSecond                    int64  `json:"-"`
}

type TransferItem struct {
	RelativePath    string
	LocalPath       string
	Remote          RemoteRef
	Size            int64
	CheckpointBytes int64 `json:",omitempty"`
	Directory       bool
	Complete        bool
	Skipped         bool
	Verified        bool
	LocalReceipt    downloadLocalReceipt `json:",omitzero"`
	Trashed         bool                 `json:",omitempty"`
	CanRebind       bool                 `json:",omitempty"`
	Error           string
}

func (j TransferJob) StatusText() string {
	if j.RemovalPending {
		return "待完成清理"
	}
	switch j.State {
	case TransferWaitingAccount:
		return "等待账号"
	case TransferPaused:
		return "已暂停"
	case TransferCompleted:
		return "已完成"
	case TransferCanceled:
		return "已取消"
	case TransferNeedsCheck:
		return "待核对"
	case TransferFailed:
		if slices.ContainsFunc(j.Items, func(i TransferItem) bool { return i.Complete || i.Skipped }) {
			return "部分失败"
		}
		if j.Direction == TransferUpload {
			return "上传失败"
		}
		return "下载失败"
	case TransferRunning:
		switch j.Stage {
		case "preparing":
			if j.Direction == TransferUpload {
				return "正在准备"
			}
			return "准备中"
		case "committing", "verifying", "cleanup":
			return "正在完成"
		default:
			if j.Direction == TransferUpload {
				return "正在上传"
			}
			return "下载中"
		}
	}
	if j.Direction == TransferUpload {
		return "等待上传"
	}
	return "等待下载"
}

type savedDownload struct {
	Folder            platform.LocalReference
	Roots             []DownloadTaskItem
	Plan              []DownloadTaskItem
	Cleanup           *ShareCleanup
	Share             bool
	CleanupAfterShare bool
}

type transferRecord struct {
	TransferJob
	Upload              *core.UploadRequest
	Download            *savedDownload
	Priority            int64
	UploadTrail         []RemoteEntry `json:",omitempty"`
	UploadSignature     string        `json:",omitempty"`
	DuplicateCandidates []string      `json:",omitempty"`
}

type transferRecords interface {
	Read(string, any) error
	Write(string, any) error
}

type uploadRunner interface {
	Run(context.Context, core.UploadRequest, core.UploadProviders, func(core.UploadProgress)) (core.UploadResult, error)
}

type downloadRunner interface {
	Run(context.Context, download.Request, download.Resolve, func(int64, int64)) (download.Result, error)
	Acknowledge(string) error
	Discard(download.Request) error
}

type Transfers struct {
	mu                sync.Mutex
	wg                sync.WaitGroup
	closed            bool
	suspended         bool
	applyProxy        func()
	records           transferRecords
	accounts          *Accounts
	shares            *ShareTransfer
	upload            uploadRunner
	download          downloadRunner
	config            TransferConfig
	notify            func() // Must enqueue UI work without waiting for the main thread.
	jobs              []transferRecord
	active            map[string]*transferWorker
	uploadChecks      map[string]uploadCheck
	beginActivity     func() (func(), error)
	downloadRate      *transferRate
	uploadRate        *transferRate
	downloadSlots     downloadSlots
	removingDownloads map[string]bool
}

const transferRecordName = "transfers"

var errTransferMissing = errors.New("找不到传输任务")

func NewTransfers(data *store.Store, accounts *Accounts, client *http.Client, config TransferConfig, notify func()) (*Transfers, error) {
	rate := newTransferRate(max(config.DownloadBytesPerSecond, 0))
	content := contentTransferClient(client, rate)
	t, err := newTransfers(data, accounts, core.NewUploader(data, content), download.New(data, content), config, notify)
	if err != nil {
		return nil, err
	}
	t.beginActivity = platform.BeginTransferActivity
	t.downloadRate = rate
	t.uploadRate = newTransferRate(max(config.UploadBytesPerSecond, 0))
	return t, nil
}

func newTransfers(data transferRecords, accounts *Accounts, upload uploadRunner, download downloadRunner, config TransferConfig, notify func()) (*Transfers, error) {
	t := &Transfers{
		records: data, accounts: accounts, upload: upload, download: download,
		config: normalizedTransferConfig(config), notify: notify, active: make(map[string]*transferWorker),
		uploadChecks: make(map[string]uploadCheck),
	}
	if shares, ok := data.(shareRecords); ok {
		t.shares = newShareTransfer(shares, accounts)
	}
	err := data.Read(transferRecordName, &t.jobs)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	seen := make(map[string]bool, len(t.jobs))
	for i := range t.jobs {
		job := &t.jobs[i]
		if job.ID == "" || seen[job.ID] || job.AccountID == "" || !validTransferProvider(job.Provider) ||
			(job.Direction != TransferUpload || job.Upload == nil || job.Download != nil) &&
				(job.Direction != TransferDownload || job.Download == nil || job.Upload != nil) {
			return nil, errors.New("传输任务记录无效")
		}
		seen[job.ID] = true
		if job.State == TransferRunning {
			job.State = TransferQueued
			job.Stage = ""
		}
	}
	return t, nil
}

func validTransferProvider(provider Provider) bool { return provider == Baidu || provider == Quark }

func TransferConfigFromSettings(values SettingsValues) TransferConfig {
	return TransferConfig{
		DownloadFiles: values.MaxConcurrentFiles, UploadJobs: values.MaxConcurrentUploads,
		BaiduConnections: values.Baidu.ConnectionsPerFile, QuarkConnections: values.Quark.ConnectionsPerFile,
		UploadParts: values.UploadPartsPerFile, UploadBytesPerSecond: values.UploadBytesPerSecond,
		DownloadBytesPerSecond: values.DownloadBytesPerSecond,
	}
}

func normalizedTransferConfig(config TransferConfig) TransferConfig {
	config.DownloadFiles = max(1, min(config.DownloadFiles, MaxDownloadFiles))
	config.UploadJobs = max(1, min(config.UploadJobs, MaxUploadTasks))
	config.UploadParts = max(1, min(config.UploadParts, MaxUploadParts))
	maxConnections := min(MaxDownloadConnections, TotalDownloadConnections/config.DownloadFiles)
	config.BaiduConnections = max(1, min(config.BaiduConnections, maxConnections))
	config.QuarkConnections = max(1, min(config.QuarkConnections, maxConnections))
	config.UploadBytesPerSecond = max(config.UploadBytesPerSecond, 0)
	config.DownloadBytesPerSecond = max(config.DownloadBytesPerSecond, 0)
	return config
}

func (t *Transfers) Configure(config TransferConfig) {
	t.mu.Lock()
	t.config = normalizedTransferConfig(config)
	t.signalDownloadSlotsLocked()
	if t.downloadRate != nil {
		t.downloadRate.set(t.config.DownloadBytesPerSecond)
	}
	if t.uploadRate != nil {
		t.uploadRate.set(t.config.UploadBytesPerSecond)
	}
	t.scheduleLocked()
	t.mu.Unlock()
	t.changed()
}

func (t *Transfers) Snapshot() []TransferJob {
	t.mu.Lock()
	defer t.mu.Unlock()
	result := make([]TransferJob, len(t.jobs))
	for i, saved := range t.jobs {
		job := saved.TransferJob
		job.CanRetryShareCleanup = canRetryShareCleanup(saved)
		job.Items = slices.Clone(job.Items)
		worker := t.active[job.ID]
		if worker != nil {
			job.Stopping = worker.stop != "" || worker.cleanupOnly || job.DuplicateOf != ""
			job.BytesPerSecond = worker.speed
			job.Done, job.Total = worker.done, worker.total
		} else if job.State == TransferQueued && !t.hasAccount(job) {
			job.State = TransferWaitingAccount
		}
		if binding, ok := t.uploadChecks[job.ID]; ok {
			job.Stopping, job.RebindingPath = true, binding.relativePath
		}
		job.Stopping = job.Stopping || t.removingDownloads[job.ID]
		result[i] = job
	}
	return result
}

func (t *Transfers) EnqueueUpload(target DirectoryTarget, sources []platform.LocalReference) (string, error) {
	session, err := target.Session(t.accounts)
	if err != nil {
		return "", err
	}
	if !validTransferProvider(target.Ref.Provider) || len(sources) == 0 {
		return "", errors.New("请选择要上传的文件或文件夹。")
	}
	for _, source := range sources {
		if !filepath.IsAbs(source.Path) {
			return "", errors.New("上传源路径无效。")
		}
	}
	dest := core.UploadTarget{Provider: string(target.Ref.Provider), AccountID: session.ID, Path: target.Ref.Path}
	if target.Ref.Provider == Baidu {
		dest.FSID, err = strconv.ParseInt(target.Ref.ID, 10, 64)
		if err != nil {
			return "", ErrDirectoryEntryChanged
		}
	} else {
		dest.FID = target.Ref.ID
	}
	ownedSources := slices.Clone(sources)
	for i := range ownedSources {
		ownedSources[i].Bookmark = slices.Clone(ownedSources[i].Bookmark)
	}
	title := batchTitle(filepath.Base(ownedSources[0].Path), len(ownedSources))
	job := newTransferJob(target.Ref.Provider, session, title, TransferUpload)
	return t.enqueue(session, transferRecord{TransferJob: job, UploadTrail: slices.Clone(target.Trail), Upload: &core.UploadRequest{
		ID: job.ID, Target: dest, Sources: ownedSources, ConflictPolicy: core.UploadKeepBoth,
	}})
}

func (t *Transfers) EnqueueDownload(selection DirectorySelection, folder platform.LocalReference) (string, error) {
	session, err := selection.Target.Session(t.accounts)
	if err != nil {
		return "", err
	}
	if len(selection.Items) == 0 {
		return "", errors.New("请选择要下载的项目。")
	}
	roots := make([]DownloadTaskItem, len(selection.Items))
	for i, item := range selection.Items {
		roots[i] = DownloadTaskItem{Entry: item.Entry, RelativePath: item.Entry.Name}
	}
	title := batchTitle(roots[0].Entry.Name, len(roots))
	return t.enqueueDownload(selection.Target.Ref.Provider, session, title, folder, roots, nil, nil)
}

func (t *Transfers) EnqueuePreparedDownload(provider Provider, session AccountSession, title string, items []DownloadTaskItem, folder platform.LocalReference, cleanup *ShareCleanup) (string, error) {
	return t.enqueueDownload(provider, session, title, folder, nil, slices.Clone(items), cleanup)
}

// EnqueueShare saves the frozen selection before adding a visible job. The
// worker performs remote transfer and download after the dialog can close.
func (t *Transfers) EnqueueShare(selection ShareSelection, folder platform.LocalReference, transferFolder string, cleanupAfterDownload bool) (string, error) {
	if t.shares == nil || !validTransferProvider(selection.Provider()) || !filepath.IsAbs(folder.Path) {
		return "", errors.New("下载目录或所选项目无效。")
	}
	job := newTransferJob(selection.Provider(), selection.access.session, selection.Title(), TransferDownload)
	job.ShareURL = selection.access.link.URL
	if err := t.shares.Stage(job.ID, selection, transferFolder); err != nil {
		return "", errors.Join(err, t.shares.DiscardStage(job.ID))
	}
	folder.Bookmark = slices.Clone(folder.Bookmark)
	id, err := t.enqueue(selection.access.session, transferRecord{TransferJob: job, Download: &savedDownload{
		Folder: folder, Share: true, CleanupAfterShare: cleanupAfterDownload,
	}})
	if err != nil {
		return "", errors.Join(err, t.shares.DiscardStage(job.ID))
	}
	return id, nil
}

func (t *Transfers) enqueueDownload(provider Provider, session AccountSession, title string, folder platform.LocalReference, roots, plan []DownloadTaskItem, cleanup *ShareCleanup) (string, error) {
	if !validTransferProvider(provider) || !filepath.IsAbs(folder.Path) || len(roots)+len(plan) == 0 {
		return "", errors.New("下载目录或所选项目无效。")
	}
	if cleanup != nil && (cleanup.Provider != provider || cleanup.AccountID != session.ID) {
		return "", ErrDirectorySessionChanged
	}
	if cleanup != nil {
		owned := *cleanup
		cleanup = &owned
	}
	folder.Bookmark = slices.Clone(folder.Bookmark)
	job := newTransferJob(provider, session, title, TransferDownload)
	record := transferRecord{TransferJob: job, Download: &savedDownload{
		Folder: folder, Roots: roots, Plan: plan, Cleanup: cleanup, CleanupAfterShare: cleanup != nil,
	}}
	if plan != nil {
		record.Items, record.Total = plannedItems(plan)
	}
	return t.enqueue(session, record)
}

func newTransferJob(provider Provider, session AccountSession, title string, direction TransferDirection) TransferJob {
	return TransferJob{
		ID: strings.ToLower(rand.Text()), Title: title, Provider: provider, AccountID: session.ID,
		AccountName: session.Name, Direction: direction, State: TransferQueued, CreatedAt: time.Now(),
	}
}

func batchTitle(first string, count int) string {
	if count == 1 {
		return first
	}
	return fmt.Sprintf("%s 等 %d 项", first, count)
}

func (t *Transfers) enqueue(session AccountSession, job transferRecord) (string, error) {
	t.mu.Lock()
	defer func() {
		t.mu.Unlock()
		t.changed()
	}()
	if t.closed {
		return "", fs.ErrClosed
	}
	current := t.accounts.Session(job.Provider)
	if current.State != LoggedIn || current.ID == "" || !sameDirectorySession(session, current) {
		return "", ErrDirectorySessionChanged
	}
	if job.Upload != nil {
		for _, candidate := range t.jobs {
			if matchingUploadTarget(candidate, job) && eligibleDuplicate(candidate, false) {
				job.DuplicateCandidates = append(job.DuplicateCandidates, candidate.ID)
			}
		}
	}
	next := append([]transferRecord{job}, t.jobs...)
	if err := t.records.Write(transferRecordName, next); err != nil {
		return "", err
	}
	t.jobs = next
	t.scheduleLocked()
	return job.ID, nil
}

func (t *Transfers) hasAccount(job TransferJob) bool {
	session := t.accounts.Session(job.Provider)
	return session.State == LoggedIn && session.ID == job.AccountID
}

func (t *Transfers) changed() {
	if t.notify != nil {
		t.notify()
	}
}
