package app

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

type removalFixtureRecords struct {
	mu          sync.Mutex
	values      map[string][]byte
	failArchive bool
}

func (r *removalFixtureRecords) Read(key string, dst any) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	data, ok := r.values[key]
	if !ok {
		return fs.ErrNotExist
	}
	return json.Unmarshal(data, dst)
}

func (r *removalFixtureRecords) Write(key string, value any) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.failArchive && strings.HasPrefix(key, "download-integrity-") {
		return errors.New("归档磁盘写入失败")
	}
	data, err := json.Marshal(value)
	if err == nil {
		r.values[key] = data
	}
	return err
}

func fixtureDownloadRemoval(t *testing.T, names ...string) (*removalFixtureRecords, transferRecord) {
	t.Helper()
	folder := platform.LocalReference{Path: t.TempDir()}
	job := transferRecord{
		TransferJob: newTransferJob(Baidu, AccountSession{ID: "owner", Name: "测试账号"}, "下载任务", TransferDownload),
		Download:    &savedDownload{Folder: folder},
	}
	job.State = TransferCompleted
	for i, name := range names {
		ref := RemoteRef{Provider: Baidu, ID: fmt.Sprint(i + 1), Path: "/" + name}
		data := []byte("test")
		local := filepath.Join(folder.Path, name)
		if err := os.MkdirAll(filepath.Dir(local), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(local, data, 0o600); err != nil {
			t.Fatal(err)
		}
		receipt, err := rememberDownloadFile(folder, local, int64(len(data)))
		if err != nil || receipt.Identity.ID == 0 {
			t.Fatalf("测试文件未获得身份记录: %+v, %v", receipt, err)
		}
		plan := DownloadTaskItem{
			Entry:        RemoteEntry{Ref: ref, Name: filepath.Base(name), Size: int64(len(data))},
			RelativePath: filepath.ToSlash(name), ExpectedSHA256: fmt.Sprintf("%x", sha256.Sum256(data)),
		}
		job.Download.Plan = append(job.Download.Plan, plan)
		job.Items = append(job.Items, TransferItem{
			RelativePath: plan.RelativePath, LocalPath: local, Remote: ref, Size: int64(len(data)),
			Complete: true, Verified: true, LocalReceipt: receipt,
		})
	}
	records := &removalFixtureRecords{values: make(map[string][]byte)}
	if err := records.Write(transferRecordName, []transferRecord{job}); err != nil {
		t.Fatal(err)
	}
	return records, job
}

func fixtureRemovalTransfers(t *testing.T, records *removalFixtureRecords) *Transfers {
	t.Helper()
	transfers, err := newTransfers(records, &Accounts{}, nil, nil, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(transfers.Close)
	return transfers
}

func TestRemovalArchivesBeforeTrashAndRetriesOnlyPendingAfterRestore(t *testing.T) {
	records, job := fixtureDownloadRemoval(t, "共同目录/甲 (1).txt", "共同目录/乙.txt")
	userFile := filepath.Join(job.Download.Folder.Path, "共同目录", "用户文件.txt")
	if err := os.WriteFile(userFile, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	transfers := fixtureRemovalTransfers(t, records)
	records.failArchive = true
	calls := []string{}
	archiveKey := fmt.Sprintf("download-integrity-%x", sha256.Sum256([]byte(job.ID)))
	trash := func(name string) error {
		calls = append(calls, name)
		var archive archivedDownload
		if err := records.Read(archiveKey, &archive); err != nil || len(archive.Items) != 2 ||
			archive.AccountID != "owner" || !archive.Items[0].Verified {
			return fmt.Errorf("回收站操作前未归档准确依据: %+v, %v", archive, err)
		}
		if name == job.Items[1].LocalPath {
			return errors.New("模拟系统回收站拒绝")
		}
		return os.Remove(name) // Emulates the system trash for an isolated fixture.
	}
	if err := transfers.removeAndTrash(job.ID, trash); err == nil || len(calls) != 0 || transfers.Snapshot()[0].RemovalPending {
		t.Fatalf("归档失败时已开始清理: %v, %v", err, calls)
	}
	if err := transfers.Remove(job.ID); err == nil || len(transfers.Snapshot()) != 1 {
		t.Fatalf("仅移除记录也必须保存校验依据: %v", err)
	}
	records.failArchive = false
	if err := transfers.removeAndTrash(job.ID, trash); err == nil || len(calls) != 2 {
		t.Fatalf("部分失败未保留: %v, %v", err, calls)
	}
	snapshot := transfers.Snapshot()[0]
	if !snapshot.RemovalPending || !snapshot.Items[0].Trashed || snapshot.Items[1].Trashed {
		t.Fatalf("清理回执状态不符: %+v", snapshot)
	}
	if err := transfers.Remove(job.ID); err == nil {
		t.Fatal("部分清理中仍可清除任务")
	}
	transfers.Close()
	transfers = fixtureRemovalTransfers(t, records)
	calls = nil
	if err := transfers.removeAndTrash(job.ID, func(name string) error {
		calls = append(calls, name)
		return os.Remove(name)
	}); err != nil || len(calls) != 1 || calls[0] != job.Items[1].LocalPath || len(transfers.Snapshot()) != 0 {
		t.Fatalf("恢复后重试清理范围不符: %v, %v", err, calls)
	}
	if got, err := os.ReadFile(userFile); err != nil || string(got) != "keep" {
		t.Fatalf("共同目录的用户文件被改动: %q, %v", got, err)
	}
}

func TestRemovalKeepsReplacementAndOlderUnprovenRecord(t *testing.T) {
	records, job := fixtureDownloadRemoval(t, "样本.txt")
	original := job.Items[0].LocalPath
	moved := filepath.Join(job.Download.Folder.Path, "原件.txt")
	if err := os.Rename(original, moved); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(original, []byte("same"), 0o600); err != nil {
		t.Fatal(err)
	}
	transfers := fixtureRemovalTransfers(t, records)
	calls := 0
	trash := func(string) error { calls++; return nil }
	if err := transfers.removeAndTrash(job.ID, trash); err == nil || calls != 0 {
		t.Fatalf("清理了同大小替换文件: %v", err)
	}
	if got, err := os.ReadFile(original); err != nil || string(got) != "same" {
		t.Fatalf("替换文件未保留: %q, %v", got, err)
	}
	transfers.Close()

	job.Items[0].LocalReceipt = downloadLocalReceipt{}
	if err := records.Write(transferRecordName, []transferRecord{job}); err != nil {
		t.Fatal(err)
	}
	transfers = fixtureRemovalTransfers(t, records)
	if err := transfers.removeAndTrash(job.ID, trash); err == nil || calls != 0 ||
		transfers.Snapshot()[0].RemovalPending {
		t.Fatalf("旧记录未确认身份却开始清理: %v", err)
	}
	if err := transfers.Remove(job.ID); err != nil || len(transfers.Snapshot()) != 0 {
		t.Fatalf("旧记录无法仅移除记录: %v", err)
	}
}

func TestTrashRejectsReplacedAbsoluteRoot(t *testing.T) {
	parent := t.TempDir()
	folder := platform.LocalReference{Path: filepath.Join(parent, "下载")}
	if err := os.Mkdir(folder.Path, 0o700); err != nil {
		t.Fatal(err)
	}
	name := filepath.Join(folder.Path, "文件.txt")
	if err := os.WriteFile(name, []byte("ours"), 0o600); err != nil {
		t.Fatal(err)
	}
	receipt, err := rememberDownloadFile(folder, name, 4)
	if err != nil {
		t.Fatal(err)
	}
	root, err := os.OpenRoot(folder.Path)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	if err := os.Rename(folder.Path, filepath.Join(parent, "已移动")); err != nil {
		t.Skipf("环境禁止移动已打开的目录: %v", err)
	}
	if err := os.Mkdir(folder.Path, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(name, []byte("user"), 0o600); err != nil {
		t.Fatal(err)
	}
	called := false
	err = trashDownloadedFile(root, TransferItem{Size: 4, LocalReceipt: receipt}, func(string) error {
		called = true
		return nil
	})
	if err == nil || called {
		t.Fatalf("旧绝对路径上的新文件不应进入系统回收站: %v", err)
	}
}
