package core

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io/fs"
	"slices"
	"time"

	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

// ErrUploadSourceNotRebindable means that this item cannot be safely reassociated.
var ErrUploadSourceNotRebindable = errors.New("请选择已有原始校验值、尚待上传的文件；目录或未建立校验基准的项目请重新添加")

func (u *Uploader) claim(id string) (func(), error) {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.active[id] {
		return nil, errors.New("上传任务正在运行")
	}
	u.active[id] = true
	return func() {
		u.mu.Lock()
		delete(u.active, id)
		u.mu.Unlock()
	}, nil
}

func uploadJobKey(id string) string {
	return fmt.Sprintf("upload-%x", sha256.Sum256([]byte(id)))
}

func uploadItemKey(jobKey, relative string) string {
	key := fmt.Sprintf("%s-%x", jobKey, sha256.Sum256([]byte(relative)))
	return fmt.Sprintf("upload-item-%x", sha256.Sum256([]byte(key)))
}

func canRebindUploadSource(entry uploadLocalItem, state uploadItemState) bool {
	return !entry.Directory && !state.Complete && !state.Skipped && !state.Remote.identified() &&
		state.Intent == "" && state.Fingerprint.SHA256 != "" && state.Fingerprint.PartSize > 0
}

// RebindSource replaces one local file location after comparing the whole
// original content and its negotiated parts. Use the unchanged UploadRequest
// when retrying. No account, destination, session or part record is rewritten.
func (u *Uploader) RebindSource(ctx context.Context, id, relativePath string, replacement platform.LocalReference) error {
	if id == "" || !fs.ValidPath(relativePath) || relativePath == "." {
		return ErrUploadSourceNotRebindable
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	release, err := u.claim(id)
	if err != nil {
		return err
	}
	defer release()
	key := uploadJobKey(id)
	var manifest uploadManifest
	if err := u.records.Read(key, &manifest); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return ErrUploadSourceNotRebindable
		}
		return err
	}
	index := slices.IndexFunc(manifest.Entries, func(entry uploadLocalItem) bool { return entry.Relative == relativePath })
	if index < 0 {
		return ErrUploadSourceNotRebindable
	}
	entry := manifest.Entries[index]
	var state uploadItemState
	if err := u.records.Read(uploadItemKey(key, relativePath), &state); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return ErrUploadSourceNotRebindable
		}
		return err
	}
	if !canRebindUploadSource(entry, state) {
		return ErrUploadSourceNotRebindable
	}
	candidate := entry
	candidate.Inside = "."
	candidate.Modified = time.Time{}
	source, err := openUploadSource(replacement, candidate)
	if err != nil {
		return err
	}
	defer source.close()
	basis := state.Fingerprint
	fingerprint, err := source.fingerprint(ctx, basis.PartSize)
	if err != nil {
		return err
	}
	if fingerprint.SHA256 != basis.SHA256 || fingerprint.MD5 != basis.MD5 || fingerprint.SHA1 != basis.SHA1 ||
		!slices.Equal(fingerprint.Parts, basis.Parts) {
		return ErrUploadSourceChanged
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	resolved := source.access.Reference
	entry.Replacement = &resolved
	entry.Modified = source.info.ModTime()
	manifest.Entries[index] = entry
	return u.records.Write(key, manifest)
}
