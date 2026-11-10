package app

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"slices"
	"strings"

	"github.com/yjcdon/ferry-drive/desktop/internal/download"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

type archivedDownload struct {
	JobID     string
	AccountID string
	Provider  Provider
	Items     []archivedDownloadItem
}

type archivedDownloadItem struct {
	Remote       RemoteRef
	RelativePath string
	Size         int64
	MD5, SHA256  string
	Verified     bool
}

// archiveDownload preserves explicit original expectations before a job is
// cleared. Provider list MD5 alone is never promoted to an archived basis.
func (t *Transfers) archiveDownload(job transferRecord) error {
	if job.Download == nil {
		return nil
	}
	archive := archivedDownload{JobID: job.ID, AccountID: job.AccountID, Provider: job.Provider}
	for i, planned := range job.Download.Plan {
		if planned.ExpectedMD5 == "" && planned.ExpectedSHA256 == "" {
			continue
		}
		if len(archive.Items) >= 10000 {
			return errors.New("校验清单超过 10000 项，请保留任务记录")
		}
		if i >= len(job.Items) {
			return errors.New("校验依据缺少对应的下载文件")
		}
		item := job.Items[i]
		if item.Directory || item.Remote != planned.Entry.Ref || item.RelativePath != planned.RelativePath ||
			item.Size != planned.Entry.Size || item.Size < 0 || item.Remote.Provider != job.Provider ||
			item.Remote.ID == "" || item.Remote.ID == "0" || job.AccountID == "" ||
			!fs.ValidPath(item.RelativePath) || item.RelativePath == "." || strings.ContainsRune(item.RelativePath, 0) ||
			planned.ExpectedMD5 != "" && usableMD5(planned.ExpectedMD5) == "" || !validArchiveSHA256(planned.ExpectedSHA256) {
			return errors.New("校验依据未匹配当前任务、文件或大小，已保留任务")
		}
		archive.Items = append(archive.Items, archivedDownloadItem{
			Remote: item.Remote, RelativePath: item.RelativePath, Size: item.Size,
			MD5: strings.ToLower(planned.ExpectedMD5), SHA256: strings.ToLower(planned.ExpectedSHA256),
			Verified: item.Complete && item.Verified && item.LocalPath != "",
		})
	}
	if len(archive.Items) == 0 {
		return nil
	}
	key := fmt.Sprintf("download-integrity-%x", sha256.Sum256([]byte(job.ID)))
	if err := t.records.Write(key, archive); err != nil {
		return fmt.Errorf("归档下载校验依据: %w", err)
	}
	return nil
}

func validArchiveSHA256(value string) bool {
	if value == "" {
		return true
	}
	if len(value) != sha256.Size*2 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

// HasLocalDownloads identifies rows that can offer the separate trash action.
// Old rows with no provable identity are still reported to the user on request.
func (j TransferJob) HasLocalDownloads() bool {
	return j.Direction == TransferDownload && slices.ContainsFunc(j.Items, func(item TransferItem) bool {
		return item.Complete && !item.Directory && item.LocalPath != ""
	})
}

// RemoveAndTrash archives the job, moves only its exact completed files to the
// system trash, and clears the row after every file is confirmed. On a partial
// failure the same action can retry without repeating confirmed moves.
func (t *Transfers) RemoveAndTrash(id string) error {
	return t.removeAndTrash(id, platform.TrashLocalItem)
}

func (t *Transfers) removeAndTrash(id string, trash func(string) error) error {
	job, err := t.beginDownloadRemoval(id)
	if err != nil {
		return err
	}
	defer func() {
		t.mu.Lock()
		delete(t.removingDownloads, id)
		t.mu.Unlock()
		t.changed()
		t.wg.Done()
	}()
	t.changed()
	access, err := platform.OpenLocalItem(job.Download.Folder)
	if err != nil {
		return fmt.Errorf("打开下载目录: %w", err)
	}
	defer access.Close()
	root, err := os.OpenRoot(access.Reference.Path)
	if err != nil {
		return err
	}
	defer root.Close()
	if err := t.archiveDownload(job); err != nil {
		return err
	}
	if !job.RemovalPending {
		job.RemovalPending = true
		if err := t.saveRemovalJob(job); err != nil {
			return err
		}
	}
	var failed []error
	for i, item := range job.Items {
		if !item.Complete || item.Directory || item.LocalPath == "" || item.Trashed {
			continue
		}
		if err := trashDownloadedFile(root, item, trash); err != nil {
			failed = append(failed, fmt.Errorf("%s: %w", item.LocalPath, err))
			continue
		}
		job.Items[i].Trashed = true
		if err := t.saveRemovalJob(job); err != nil {
			return errors.Join(append(failed, err)...)
		}
	}
	if len(failed) != 0 {
		return errors.Join(failed...)
	}
	if err := t.discardDownloadPartials(job); err != nil {
		return err
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.removeRecordLocked(t.find(id))
}

func (t *Transfers) beginDownloadRemoval(id string) (transferRecord, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return transferRecord{}, fs.ErrClosed
	}
	index := t.find(id)
	if index < 0 {
		return transferRecord{}, errTransferMissing
	}
	job := t.jobs[index]
	if job.Download == nil || t.active[id] != nil || t.removingDownloads[id] ||
		job.State != TransferCompleted && job.State != TransferFailed || !job.HasLocalDownloads() {
		return transferRecord{}, errors.New("当前任务无法移除已下载文件")
	}
	if slices.ContainsFunc(job.Items, func(item TransferItem) bool {
		return item.Complete && !item.Directory && item.LocalPath != "" && !item.Trashed && item.LocalReceipt.Identity.ID == 0
	}) {
		return transferRecord{}, errors.New("缺少本地文件身份，已保留任务与文件")
	}
	job.Items = slices.Clone(job.Items)
	if t.removingDownloads == nil {
		t.removingDownloads = make(map[string]bool)
	}
	t.removingDownloads[id] = true
	t.wg.Add(1)
	return job, nil
}

func (t *Transfers) saveRemovalJob(job transferRecord) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	job.Items = slices.Clone(job.Items)
	if err := t.replaceLocked(t.find(job.ID), job); err != nil {
		return fmt.Errorf("保存下载清理进度: %w", err)
	}
	return nil
}

func (t *Transfers) removeRecordLocked(index int) error {
	next := slices.Delete(slices.Clone(t.jobs), index, index+1)
	if err := t.records.Write(transferRecordName, next); err != nil {
		return err
	}
	t.jobs = next
	return nil
}

func (t *Transfers) discardDownloadPartials(job transferRecord) error {
	if job.Download == nil || t.download == nil {
		return nil
	}
	for i, item := range job.Download.Plan {
		if item.Entry.IsDirectory {
			continue
		}
		if err := t.download.Discard(download.Request{ID: downloadItemID(job.ID, i), Folder: job.Download.Folder,
			RelativePath: item.RelativePath, Size: item.Entry.Size}); err != nil {
			return fmt.Errorf("%s：%w", item.RelativePath, err)
		}
	}
	return nil
}
