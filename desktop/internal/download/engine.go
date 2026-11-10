// Package download transfers one known-size remote file and records resumable progress.
package download

import (
	"context"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
	"github.com/yjcdon/ferry-drive/desktop/internal/store"
)

// ErrIntegrityMismatch means downloaded bytes differ from the expected digest.
var ErrIntegrityMismatch = errors.New("下载内容校验不匹配")

type Request struct {
	ID             string
	Folder         platform.LocalReference
	RelativePath   string // Remote slash-separated path under Folder.
	Size           int64
	Connections    int // 0 uses one connection.
	ExpectedMD5    string
	ExpectedSHA256 string
}

// Result gives the actual published path and the current destination reference.
// Verified requires matching at least one supplied digest.
type Result struct {
	Path     string
	Verified bool
	Folder   platform.LocalReference
}

type Link struct {
	URL     string
	Headers http.Header
}

type Resolve func(context.Context) (Link, error)

type checkpointStore interface {
	Read(string, any) error
	Write(string, any) error
	Remove(string) error
}

// Engine coordinates active work and durable checkpoints for a single process.
type Engine struct {
	records checkpointStore
	client  *http.Client
	mu      sync.Mutex
	active  map[string]bool
}

func New(records *store.Store, client *http.Client) *Engine {
	return newEngine(records, client)
}

func newEngine(records checkpointStore, client *http.Client) *Engine {
	return &Engine{records: records, client: redirectClient(client), active: make(map[string]bool)}
}

type checkpoint struct {
	Target     string         `json:"target"`
	Folder     string         `json:"folder"`
	Size       int64          `json:"size"`
	MD5        string         `json:"md5,omitempty"`
	SHA256     string         `json:"sha256,omitempty"`
	Partial    string         `json:"partial"`
	Chunks     map[int64]bool `json:"chunks,omitempty"`
	Full       bool           `json:"full,omitempty"`
	WholeBytes int64          `json:"wholeBytes,omitempty"`
	Entity     entity         `json:"entity"`
	Candidate  string         `json:"candidate,omitempty"`
	Stamp      *fileStamp     `json:"stamp,omitempty"`
	Published  bool           `json:"published,omitempty"`
}

type transfer struct {
	name     string
	dir      *os.Root
	record   checkpoint
	records  checkpointStore
	file     *os.File
	saved    time.Time
	dirty    bool
	done     int64
	progress func(int64, int64)
}

// Run downloads or resumes one file. Callers cancel its context to pause and
// wait for Run to return before resuming. Progress runs on the calling goroutine.
func (e *Engine) Run(ctx context.Context, req Request, resolve Resolve, progress func(done, total int64)) (Result, error) {
	if req.ID == "" || req.Size < 0 || req.Connections < 0 || req.Connections > 16 || resolve == nil {
		return Result{}, errors.New("下载参数无效")
	}
	req.ExpectedMD5, req.ExpectedSHA256 = strings.ToLower(req.ExpectedMD5), strings.ToLower(req.ExpectedSHA256)
	if !validDigest(req.ExpectedMD5, md5.Size) || !validDigest(req.ExpectedSHA256, sha256.Size) {
		return Result{}, errors.New("下载内容校验值格式无效")
	}
	rel, err := platform.DownloadRelativePath(req.RelativePath)
	if err != nil {
		return Result{}, err
	}
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}

	name, release, err := e.claim(req.ID)
	if err != nil {
		return Result{}, err
	}
	defer release()
	access, err := platform.OpenLocalItem(req.Folder)
	if err != nil {
		return Result{}, fmt.Errorf("打开下载目录: %w", err)
	}
	defer access.Close()
	root, err := os.OpenRoot(access.Reference.Path)
	if err != nil {
		return Result{}, fmt.Errorf("打开下载目录: %w", err)
	}
	defer root.Close()
	parent := filepath.Dir(rel)
	if err := root.MkdirAll(parent, 0o755); err != nil {
		return Result{}, fmt.Errorf("创建下载子目录: %w", err)
	}
	dir, err := root.OpenRoot(parent)
	if err != nil {
		return Result{}, fmt.Errorf("打开下载子目录: %w", err)
	}
	defer dir.Close()

	t := transfer{name: name, dir: dir, records: e.records, progress: progress}
	file, err := t.run(ctx, req, rel, &linkSource{resolve: resolve, client: e.client})
	if err != nil {
		return Result{}, err
	}
	return Result{
		Path: filepath.Join(access.Reference.Path, parent, file), Folder: access.Reference,
		Verified: req.ExpectedMD5 != "" || req.ExpectedSHA256 != "",
	}, nil
}

// Acknowledge clears the completion checkpoint after the caller has persisted
// the exact path. Re-running before acknowledgment returns that same receipt.
func (e *Engine) Acknowledge(id string) error {
	name, release, err := e.claim(id)
	if err != nil {
		return err
	}
	defer release()
	var record checkpoint
	if err := e.records.Read(name, &record); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		return err
	}
	if !record.Published {
		return errors.New("下载尚未发布")
	}
	return e.records.Remove(name)
}

func (e *Engine) claim(id string) (string, func(), error) {
	name := fmt.Sprintf("download-%x", sha256.Sum256([]byte(id)))
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.active[name] {
		return "", nil, errors.New("此文件已有下载执行者")
	}
	e.active[name] = true
	return name, func() {
		e.mu.Lock()
		delete(e.active, name)
		e.mu.Unlock()
	}, nil
}

func (t *transfer) run(ctx context.Context, req Request, rel string, source *linkSource) (published string, err error) {
	if err := t.restore(req, rel); err != nil {
		return "", err
	}
	if t.record.Published {
		return t.finish()
	}
	if t.record.Candidate != "" && t.record.Stamp != nil {
		if _, err := t.dir.Lstat(t.record.Partial); errors.Is(err, fs.ErrNotExist) {
			return t.recoverPublication()
		}
	}
	if err := t.openPartial(); err != nil {
		return "", err
	}
	defer func() {
		if t.file == nil {
			return
		}
		saveErr := t.save()
		closeErr := t.file.Close()
		err = errors.Join(err, saveErr, closeErr)
	}()
	t.report(t.done)
	if err := t.transfer(ctx, source, max(req.Connections, 1)); err != nil {
		return "", err
	}
	if err := verify(ctx, t.file, t.record); err != nil {
		if errors.Is(err, ErrIntegrityMismatch) && t.record.Candidate == "" {
			t.record.Chunks = nil
			t.record.Full = false
			t.record.WholeBytes = 0
			t.record.Entity = entity{}
			t.dirty = true
		}
		return "", err
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if err := t.save(); err != nil {
		return "", err
	}
	closeErr := t.file.Close()
	t.file = nil
	if closeErr != nil {
		return "", closeErr
	}
	return t.publish(ctx, filepath.Base(rel))
}

func validDigest(value string, size int) bool {
	if value == "" {
		return true
	}
	_, err := hex.DecodeString(value)
	return len(value) == size*2 && err == nil
}

func verify(ctx context.Context, file *os.File, record checkpoint) error {
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if info.Size() != record.Size {
		return fmt.Errorf("下载文件长度 %d 与预期 %d 不一致", info.Size(), record.Size)
	}
	var outputs []io.Writer
	md5Digest, shaDigest := md5.New(), sha256.New()
	if record.MD5 != "" {
		outputs = append(outputs, md5Digest)
	}
	if record.SHA256 != "" {
		outputs = append(outputs, shaDigest)
	}
	if len(outputs) == 0 {
		return nil
	}
	n, err := io.Copy(io.MultiWriter(outputs...), contextReader{ctx, io.NewSectionReader(file, 0, record.Size)})
	if err != nil {
		return fmt.Errorf("读取下载内容校验: %w", err)
	}
	if n != record.Size || record.MD5 != "" && hex.EncodeToString(md5Digest.Sum(nil)) != record.MD5 ||
		record.SHA256 != "" && hex.EncodeToString(shaDigest.Sum(nil)) != record.SHA256 {
		return ErrIntegrityMismatch
	}
	return nil
}

type contextReader struct {
	context.Context
	io.Reader
}

func (r contextReader) Read(p []byte) (int, error) {
	if err := r.Err(); err != nil {
		return 0, err
	}
	return r.Reader.Read(p)
}
