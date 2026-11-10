package app

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/yjcdon/ferry-drive/desktop/internal/download"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
	"github.com/yjcdon/ferry-drive/desktop/internal/quark"
)

func cleanupTestPlan(session AccountSession) (DownloadTaskItem, ShareCleanup) {
	return DownloadTaskItem{
		Entry:        RemoteEntry{Ref: RemoteRef{Provider: Quark, ID: "file"}, Name: "file.txt", Size: 5},
		RelativePath: "file.txt", ExpectedMD5: "5d41402abc4b2a76b9719d911017c592",
	}, ShareCleanup{Provider: Quark, AccountID: session.ID, Root: RemoteRef{Provider: Quark, ID: "owned"}, Parent: Quark.RootRef(), Name: "FerryDrive-test"}
}

func cleanupTestList(t *testing.T, r *http.Request, id string) (*http.Response, error) {
	rows := []any{}
	if id != "" {
		rows = append(rows, map[string]any{"fid": id, "file_name": "FerryDrive-test", "dir": true, "pdir_fid": "0"})
	}
	return directoryReply(t, r, map[string]any{"status": 200, "code": 0, "data": map[string]any{"list": rows}})
}

func TestCompletedShareRetriesCleanupAfterRestartWithoutRepeatingDownload(t *testing.T) {
	deletes, downloads := 0, 0
	deleted := false
	transport := directoryTransport(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/1/clouddrive/file/sort":
			if deleted {
				return cleanupTestList(t, r, "")
			}
			return cleanupTestList(t, r, "owned")
		case "/1/clouddrive/file/delete":
			deletes++
			if deletes == 1 {
				return nil, errors.New("temporary cleanup failure")
			}
			deleted = true
			return nil, errors.New("delete succeeded but its response was lost")
		}
		return nil, fmt.Errorf("cleanup repeated transfer or requested another resource: %s", r.URL)
	})
	records := shareTestStore{make(map[string][]byte), make(map[string][]byte)}
	accounts := NewAccounts(records, nil)
	session := AccountSession{ID: "owner", State: LoggedIn, Quark: quark.New(quark.Credential{}, &http.Client{Transport: transport})}
	accounts.quark.current.Store(&session)
	item, cleanup := cleanupTestPlan(session)
	runner := downloadTestWorker{run: func(req download.Request) (download.Result, error) {
		downloads++
		result, err := downloadedFixture(req)
		result.Verified = true
		return result, err
	}}
	transfers, err := newTransfers(records, accounts, nil, runner, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer transfers.Close()
	id, err := transfers.EnqueuePreparedDownload(Quark, session, "分享", []DownloadTaskItem{item}, platform.LocalReference{Path: t.TempDir()}, &cleanup)
	if err != nil {
		t.Fatal(err)
	}
	job := waitTransferState(t, transfers, id, TransferCompleted)
	if job.Warning == "" || !job.CanRetryShareCleanup || downloads != 1 || deletes != 1 {
		t.Fatalf("automatic cleanup did not leave a retryable completed task: %+v", job)
	}
	transfers.Close()
	restored, err := newTransfers(records, accounts, nil, runner, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	if err := restored.RetryShareCleanup(t.Context(), id); err == nil {
		t.Fatal("lost deletion response did not retain the cleanup target")
	}
	if job := restored.Snapshot()[0]; !job.CanRetryShareCleanup || job.Warning == "" || job.State != TransferCompleted {
		t.Fatalf("ambiguous deletion lost the retryable completed task: %+v", job)
	}
	if err := restored.RetryShareCleanup(t.Context(), id); err != nil {
		t.Fatalf("already absent owned directory did not settle cleanup: %v", err)
	}
	job = restored.Snapshot()[0]
	if job.State != TransferCompleted || job.Warning != "" || job.CanRetryShareCleanup || job.Stopping || downloads != 1 || deletes != 2 {
		t.Fatalf("cleanup changed completed download or left retry state: %+v, downloads=%d deletes=%d", job, downloads, deletes)
	}
	if err := restored.RetryShareCleanup(t.Context(), id); err == nil || deletes != 2 {
		t.Fatalf("repeated cleanup remained available: %v, deletes=%d", err, deletes)
	}
}

func TestShareCleanupRequiresVerifiedPlanAndOriginalAccount(t *testing.T) {
	for _, scenario := range []string{"unverified", "no-expectation", "invalid-expectation", "different-file", "trashed", "wrong-account", "replacement-root"} {
		t.Run(scenario, func(t *testing.T) {
			requests, deletes := 0, 0
			transport := directoryTransport(func(r *http.Request) (*http.Response, error) {
				requests++
				if r.URL.Path == "/1/clouddrive/file/sort" {
					return cleanupTestList(t, r, "replacement")
				}
				deletes++
				return nil, errors.New("unexpected destructive request")
			})
			records := shareTestStore{make(map[string][]byte), make(map[string][]byte)}
			accounts := NewAccounts(records, nil)
			session := AccountSession{ID: "owner", State: LoggedIn, Quark: quark.New(quark.Credential{}, &http.Client{Transport: transport})}
			accounts.quark.current.Store(&session)
			item, cleanup := cleanupTestPlan(session)
			items, total := plannedItems([]DownloadTaskItem{item})
			items[0].Complete, items[0].Verified = true, true
			job := transferRecord{TransferJob: newTransferJob(Quark, session, "分享", TransferDownload), Download: &savedDownload{
				Plan: []DownloadTaskItem{item}, Cleanup: &cleanup, CleanupAfterShare: true,
			}}
			job.State, job.Items, job.Done, job.Total, job.Warning = TransferCompleted, items, total, total, "cleanup failed"
			switch scenario {
			case "unverified":
				job.Items[0].Verified = false
			case "no-expectation":
				job.Download.Plan[0].ExpectedMD5 = ""
			case "invalid-expectation":
				job.Download.Plan[0].ExpectedMD5 = strings.Repeat("0", 32)
			case "different-file":
				job.Items[0].Remote.ID = "other-file"
			case "trashed":
				job.Items[0].Trashed = true
			case "wrong-account":
				other := session
				other.ID = "other"
				accounts.quark.current.Store(&other)
			}
			if err := records.Write(transferRecordName, []transferRecord{job}); err != nil {
				t.Fatal(err)
			}
			transfers, err := newTransfers(records, accounts, nil, nil, TransferConfig{}, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer transfers.Close()
			if err := transfers.RetryShareCleanup(t.Context(), job.ID); err == nil {
				t.Fatal("invalid cleanup was accepted")
			}
			if deletes != 0 || scenario != "replacement-root" && requests != 0 {
				t.Fatalf("unsafe cleanup sent requests: %d, deletes=%d", requests, deletes)
			}
			if got := transfers.Snapshot()[0]; got.State != TransferCompleted || got.Warning == "" {
				t.Fatalf("failure lost completed state or cleanup warning: %+v", got)
			}
		})
	}
}

func TestShareCleanupBlocksRemovalAndStopsWithAccountChange(t *testing.T) {
	started := make(chan struct{})
	transport := directoryTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/1/clouddrive/file/sort" {
			return nil, errors.New("unexpected deletion after account change")
		}
		close(started)
		<-r.Context().Done()
		return nil, r.Context().Err()
	})
	records := shareTestStore{make(map[string][]byte), make(map[string][]byte)}
	accounts := NewAccounts(records, nil)
	session := AccountSession{ID: "owner", State: LoggedIn, Quark: quark.New(quark.Credential{}, &http.Client{Transport: transport})}
	accounts.quark.current.Store(&session)
	item, cleanup := cleanupTestPlan(session)
	items, total := plannedItems([]DownloadTaskItem{item})
	items[0].Complete, items[0].Verified, items[0].LocalPath = true, true, "/download/file.txt"
	job := transferRecord{TransferJob: newTransferJob(Quark, session, "分享", TransferDownload), Download: &savedDownload{
		Plan: []DownloadTaskItem{item}, Cleanup: &cleanup, CleanupAfterShare: true,
	}}
	job.State, job.Items, job.Done, job.Total, job.Warning = TransferCompleted, items, total, total, "cleanup failed"
	if err := records.Write(transferRecordName, []transferRecord{job}); err != nil {
		t.Fatal(err)
	}
	transfers, err := newTransfers(records, accounts, nil, nil, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer transfers.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- transfers.RetryShareCleanup(ctx, job.ID) }()
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("cleanup request did not start")
	}
	if snapshot := transfers.Snapshot()[0]; !snapshot.Stopping || snapshot.State != TransferCompleted || snapshot.Done != total {
		t.Fatalf("cleanup did not expose the operation barrier: %+v", snapshot)
	}
	if err := transfers.Remove(job.ID); err == nil {
		t.Fatal("removed record during cleanup")
	}
	if err := transfers.RemoveAndTrash(job.ID); err == nil {
		t.Fatal("removed local files during cleanup")
	}
	if err := transfers.RetryShareCleanup(t.Context(), job.ID); err == nil {
		t.Fatal("started concurrent cleanup")
	}
	other := session
	other.ID = "other"
	accounts.quark.current.Store(&other)
	transfers.AccountsChanged()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("account change did not stop cleanup: %v", err)
	}
	if snapshot := transfers.Snapshot()[0]; snapshot.Stopping || !snapshot.CanRetryShareCleanup || snapshot.State != TransferCompleted {
		t.Fatalf("canceled cleanup lost its retryable completed record: %+v", snapshot)
	}
}

func TestAutomaticCleanupExpiresAccountButKeepsCompletedDownload(t *testing.T) {
	transport := directoryTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/1/clouddrive/file/sort" {
			return nil, fmt.Errorf("清理不应调用其他端点: %s", r.URL)
		}
		return directoryReply(t, r, map[string]any{"status": 401, "code": 401})
	})
	accounts := NewAccounts(nil, nil)
	session := AccountSession{ID: "owner", State: LoggedIn, Quark: quark.New(quark.Credential{}, &http.Client{Transport: transport})}
	accounts.quark.current.Store(&session)
	item, cleanup := cleanupTestPlan(session)
	runner := downloadTestWorker{run: func(req download.Request) (download.Result, error) {
		result, err := downloadedFixture(req)
		result.Verified = true
		return result, err
	}}
	queue, err := newTransfers(&transferTestRecords{}, accounts, nil, runner, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer queue.Close()
	id, err := queue.EnqueuePreparedDownload(Quark, session, "分享", []DownloadTaskItem{item}, platform.LocalReference{Path: t.TempDir()}, &cleanup)
	if err != nil {
		t.Fatal(err)
	}
	job := waitTransferState(t, queue, id, TransferCompleted)
	if job.Warning == "" || !job.CanRetryShareCleanup {
		t.Fatalf("清理失败应保留已完成任务及清理入口: %+v", job)
	}
	if got := accounts.Session(Quark); got.State != Expired || got.ID != session.ID {
		t.Fatalf("自动清理应标记原账号已失效: %+v", got)
	}
}
