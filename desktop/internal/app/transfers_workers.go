package app

import (
	"context"
	"crypto/md5"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/yjcdon/ferry-drive/desktop/internal/core"
	"github.com/yjcdon/ferry-drive/desktop/internal/download"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

func (t *Transfers) runUpload(ctx context.Context, worker *transferWorker) ([]TransferItem, error) {
	req := *worker.job.Upload
	req.ParallelParts = worker.config.UploadParts
	req.BytesPerSecond = worker.config.UploadBytesPerSecond
	if t.uploadRate != nil {
		req.WaitUploadBudget = t.uploadRate.waitUpload
	}
	req.ReadbackBytesPerSecond = 0 // The content client shares one download budget.
	req.BeforeRemote = func(signature string, canPause bool) error {
		return t.checkUploadDuplicate(ctx, worker, signature, canPause)
	}
	providers := core.UploadProviders{Baidu: worker.session.Baidu, Quark: worker.session.Quark, AccountID: worker.session.ID}
	progress := make(map[string]core.UploadProgress, len(worker.job.Items))
	var done, total int64
	for _, item := range worker.job.Items {
		n := int64(0)
		if item.Complete {
			n = item.Size
		}
		progress[item.RelativePath] = core.UploadProgress{RelativePath: item.RelativePath, Done: n, Total: item.Size}
		done += n
		total += item.Size
	}
	result, err := t.upload.Run(ctx, req, providers, func(update core.UploadProgress) {
		before := progress[update.RelativePath]
		progress[update.RelativePath] = update
		done += update.Done - before.Done
		total += update.Total - before.Total
		t.report(worker, update.Phase, done, total)
	})
	items := make([]TransferItem, 0, len(result.Items))
	unconfirmed := false
	for _, item := range result.Items {
		ref := RemoteRef{Provider: worker.job.Provider, Path: item.Path, ID: item.FID}
		if item.FSID != 0 {
			ref.ID = strconv.FormatInt(item.FSID, 10)
		}
		complete := item.Error == "" && !item.Skipped
		unconfirmed = unconfirmed || strings.Contains(item.Error, core.ErrUploadUnconfirmed.Error())
		items = append(items, TransferItem{
			RelativePath: item.RelativePath, Remote: ref, Size: item.Size, Directory: item.Directory,
			Complete: complete, Skipped: item.Skipped, Verified: complete && !item.Directory, CanRebind: item.CanRebind, Error: item.Error,
		})
	}
	if unconfirmed {
		err = errors.Join(err, core.ErrUploadUnconfirmed)
	}
	return items, err
}

func mergeTransferItems(previous, updates []TransferItem) []TransferItem {
	items := slices.Clone(previous)
	indices := make(map[string]int, len(items))
	for i, item := range items {
		indices[item.RelativePath] = i
	}
	for _, item := range updates {
		if index, ok := indices[item.RelativePath]; ok {
			items[index] = item
		} else {
			indices[item.RelativePath] = len(items)
			items = append(items, item)
		}
	}
	return items
}

func completedTotals(items []TransferItem) (done, total int64) {
	for _, item := range items {
		total += item.Size
		if item.Complete {
			done += item.Size
		}
	}
	return done, total
}

func plannedItems(plan []DownloadTaskItem) ([]TransferItem, int64) {
	items := make([]TransferItem, len(plan))
	var total int64
	for i, item := range plan {
		items[i] = TransferItem{
			RelativePath: item.RelativePath, Remote: item.Entry.Ref, Size: item.Entry.Size, Directory: item.Entry.IsDirectory,
		}
		total += item.Entry.Size
	}
	return items, total
}

func (t *Transfers) runDownload(ctx context.Context, worker *transferWorker) (string, error) {
	req := *worker.job.Download
	items := slices.Clone(worker.job.Items)
	if req.Plan == nil {
		if req.Share {
			if t.shares == nil {
				return "", errors.New("分享转存记录不可用。")
			}
			if err := writableDownloadFolder(req.Folder); err != nil {
				return "", err
			}
			prepared, err := t.shares.Resume(ctx, worker.job.ID)
			if err != nil {
				return "", err
			}
			if prepared.Provider != worker.job.Provider || prepared.AccountID != worker.job.AccountID {
				return "", ErrDirectorySessionChanged
			}
			req.Plan = prepared.Items
			if prepared.Cleanup.Root.ID != "" {
				req.Cleanup = &prepared.Cleanup
			}
		} else {
			plan, err := t.planDownload(ctx, worker, req.Roots)
			if err != nil {
				return "", err
			}
			req.Plan = plan
		}
		items, _ = plannedItems(req.Plan)
		if err := t.saveDownload(worker, req, items); err != nil {
			return "", err
		}
	}
	if len(items) != len(req.Plan) {
		return "", errors.New("下载任务的项目记录无效")
	}
	if len(items) == 0 {
		return "勾选的目录中没有文件，不需要下载。", nil
	}

	if err := t.runDownloadFiles(ctx, worker, req, items); err != nil {
		return "", err
	}
	if req.Cleanup != nil && req.CleanupAfterShare {
		if !allDownloadItemsVerified(req.Plan, items) {
			return "没有删除网盘中的转存文件：没有全部文件的可信内容校验结果，已保留转存文件", nil
		}
		done, total := completedTotals(items)
		t.report(worker, "cleanup", done, total)
		if err := t.checkAccount(worker); err != nil {
			return "", err
		}
		if err := req.Cleanup.Cleanup(ctx, worker.session); err != nil {
			if ctx.Err() != nil {
				return "", ctx.Err()
			}
			return "没有删除网盘中的转存文件：" + err.Error(), nil
		}
		req.Cleanup = nil
		if err := t.saveDownload(worker, req, items); err != nil {
			return "", err
		}
	}
	return "", nil
}

func allDownloadItemsVerified(plan []DownloadTaskItem, items []TransferItem) bool {
	files := 0
	for i, item := range items {
		if item.Directory {
			continue
		}
		files++
		if !item.Verified || plan[i].ExpectedMD5 == "" && plan[i].ExpectedSHA256 == "" {
			return false
		}
	}
	return files > 0
}

func (t *Transfers) saveDownload(worker *transferWorker, req savedDownload, items []TransferItem) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	index := t.find(worker.job.ID)
	job := t.jobs[index]
	job.Download = &req
	job.Items = slices.Clone(items)
	job.Done, job.Total = completedTotals(items)
	return t.replaceLocked(index, job)
}

func (t *Transfers) planDownload(ctx context.Context, worker *transferWorker, roots []DownloadTaskItem) ([]DownloadTaskItem, error) {
	var result []DownloadTaskItem
	seen := make(map[RemoteRef]bool)
	var visit func(DownloadTaskItem) error
	visit = func(item DownloadTaskItem) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := t.checkAccount(worker); err != nil {
			return err
		}
		if item.Entry.Ref.Provider != worker.job.Provider || item.Entry.Ref.ID == "" || seen[item.Entry.Ref] {
			return errors.New("下载清单包含无效或重复的网盘对象")
		}
		seen[item.Entry.Ref] = true
		if !item.Entry.IsDirectory {
			result = append(result, item)
			return nil
		}
		children, err := listRemote(ctx, worker.session, item.Entry.Ref)
		if err != nil {
			return err
		}
		if len(children) == 0 {
			result = append(result, item)
			return nil
		}
		for _, child := range children {
			if err := visit(DownloadTaskItem{Entry: child, RelativePath: item.RelativePath + "/" + child.Name}); err != nil {
				return err
			}
		}
		return nil
	}
	for _, root := range roots {
		if err := visit(root); err != nil {
			return nil, err
		}
	}
	return result, nil
}

func (t *Transfers) downloadOne(ctx context.Context, worker *transferWorker, folder platform.LocalReference,
	file DownloadTaskItem, id string, connections int, item *TransferItem, progress func(int64, int64)) error {
	if file.Entry.Ref.Provider != worker.job.Provider || file.Entry.Ref.ID == "" {
		return ErrDirectoryEntryChanged
	}
	if file.Entry.IsDirectory {
		local, err := createDownloadDirectory(folder, file.RelativePath)
		item.LocalPath = local
		return err
	}
	expected := file.ExpectedMD5
	if expected == "" && worker.job.Provider == Quark {
		expected = usableMD5(file.Entry.MD5)
	}
	var preference int
	resolve := func(ctx context.Context) (download.Link, error) {
		if err := t.checkAccount(worker); err != nil {
			return download.Link{}, err
		}
		if file.Entry.Ref.Provider == Baidu {
			if err := checkBaiduDownload(ctx, worker.session, file.Entry); err != nil {
				return download.Link{}, err
			}
			link, err := worker.session.Baidu.DownloadLink(ctx, file.Entry.Ref.Path, preference)
			if err != nil {
				return download.Link{}, err
			}
			preference++
			return download.Link{URL: link.URL.String(), Headers: link.Headers}, nil
		}
		link, err := worker.session.Quark.Download(ctx, file.Entry.Ref.ID)
		if err != nil {
			return download.Link{}, err
		}
		if link.Size != nil && *link.Size != file.Entry.Size {
			return download.Link{}, ErrDirectoryEntryChanged
		}
		if remote := usableMD5(link.MD5); expected != "" && remote != "" && !strings.EqualFold(expected, remote) {
			return download.Link{}, ErrDirectoryEntryChanged
		}
		return download.Link{URL: link.URL.String(), Headers: link.Headers}, nil
	}
	result, err := t.download.Run(ctx, download.Request{
		ID: id, Folder: folder, RelativePath: file.RelativePath, Size: file.Entry.Size,
		Connections: connections, ExpectedMD5: expected, ExpectedSHA256: file.ExpectedSHA256,
	}, resolve, progress)
	if err != nil {
		return err
	}
	item.LocalPath, item.Verified = result.Path, result.Verified
	receipt, err := rememberDownloadFile(result.Folder, result.Path, file.Entry.Size)
	if err != nil {
		return fmt.Errorf("记录下载文件位置: %w", err)
	}
	item.LocalReceipt = receipt
	return nil
}

func usableMD5(raw string) string {
	digest, err := hex.DecodeString(raw)
	if err != nil || len(digest) != md5.Size || !slices.ContainsFunc(digest, func(b byte) bool { return b != 0 }) {
		return ""
	}
	return strings.ToLower(raw)
}

func checkBaiduDownload(ctx context.Context, session AccountSession, entry RemoteEntry) error {
	parent := RemoteRef{Provider: Baidu, Path: path.Dir(entry.Ref.Path)}
	entries, err := listRemote(ctx, session, parent)
	if err != nil {
		return err
	}
	for _, current := range entries {
		if current.Ref == entry.Ref && current.Size == entry.Size && !current.IsDirectory {
			return nil
		}
	}
	return ErrDirectoryEntryChanged
}

func createDownloadDirectory(folder platform.LocalReference, relative string) (string, error) {
	local, err := platform.DownloadRelativePath(relative)
	if err != nil {
		return "", err
	}
	access, err := platform.OpenLocalItem(folder)
	if err != nil {
		return "", err
	}
	defer access.Close()
	root, err := os.OpenRoot(access.Reference.Path)
	if err != nil {
		return "", err
	}
	defer root.Close()
	if err := root.MkdirAll(local, 0o755); err != nil {
		return "", err
	}
	return filepath.Join(access.Reference.Path, local), nil
}

func writableDownloadFolder(folder platform.LocalReference) error {
	access, err := platform.OpenLocalItem(folder)
	if err != nil {
		return err
	}
	defer access.Close()
	root, err := os.OpenRoot(access.Reference.Path)
	if err != nil {
		return err
	}
	defer root.Close()
	name := ".ferry-folder-" + rand.Text()
	file, err := root.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("下载目录不可写: %w", err)
	}
	return errors.Join(file.Close(), root.Remove(name))
}
