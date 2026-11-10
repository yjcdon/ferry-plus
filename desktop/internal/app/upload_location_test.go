package app

import (
	"errors"
	"fmt"
	"net/http"
	"reflect"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/core"
	"github.com/yjcdon/ferry-drive/desktop/internal/quark"
)

func TestLocateBaiduUploadChecksExactFileAndAccount(t *testing.T) {
	accounts := NewAccounts(nil, nil)
	reads, fileID := 0, 42
	session := newDirectorySession(t, "original", directoryTransport(func(r *http.Request) (*http.Response, error) {
		reads++
		switch r.URL.Query().Get("dir") {
		case "/":
			return directoryList(t, r, []baiduRow{{ID: 2, Path: "/目标", Directory: 1}})
		case "/目标":
			return directoryList(t, r, []baiduRow{{ID: 7, Path: "/目标/项目 (1)", Directory: 1}})
		case "/目标/项目 (1)":
			return directoryList(t, r, []baiduRow{{ID: fileID, Path: "/目标/项目 (1)/报告 (1).txt", Size: 3}})
		}
		return nil, errors.New("unexpected directory")
	}))
	accounts.baidu.current.Store(&session)
	folder := RemoteRef{Provider: Baidu, ID: "7", Path: "/目标/项目 (1)"}
	file := RemoteRef{Provider: Baidu, ID: "42", Path: "/目标/项目 (1)/报告 (1).txt"}
	job := newTransferJob(Baidu, session, "项目", TransferUpload)
	job.ID = "job"
	job.Items = []TransferItem{
		{RelativePath: "项目", Directory: true, Remote: folder},
		{RelativePath: "项目/报告.txt", Remote: file},
	}
	queue, err := newTransfers(&transferTestRecords{}, accounts, nil, nil, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	queue.jobs = []transferRecord{{TransferJob: job, Upload: &core.UploadRequest{
		ID: job.ID, Target: core.UploadTarget{Provider: string(Baidu), AccountID: session.ID, Path: "/目标", FSID: 2},
	}}}
	location, err := queue.LocateUploadCloud(t.Context(), job.ID, job.Items[1].RelativePath)
	if err != nil || reads != 3 {
		t.Fatalf("locate: err=%v, reads=%d", err, reads)
	}
	directory := NewDirectory(Baidu)
	if !location.Apply(accounts, directory) || directory.Root() != folder ||
		!reflect.DeepEqual(directory.Selection(), []RemoteRef{file}) || len(directory.Trail()) != 2 {
		t.Fatalf("wrong target or focus: %+v selected=%+v", directory.Location(), directory.Selection())
	}
	fileID = 43 // Same path and bytes, different server identity.
	if _, err := queue.LocateUploadCloud(t.Context(), job.ID, job.Items[1].RelativePath); !errors.Is(err, errUploadCloudMissing) {
		t.Fatalf("same-named replacement was accepted: %v", err)
	}
	before := reads
	other := session
	other.ID = "other"
	accounts.baidu.current.Store(&other)
	if _, err := queue.LocateUploadCloud(t.Context(), job.ID, job.Items[1].RelativePath); !errors.Is(err, errUploadCloudAccount) || reads != before {
		t.Fatalf("wrong account was used: %v, reads=%d", err, reads)
	}
	if location.Apply(accounts, directory) {
		t.Fatal("an old resolved cloud location changed the current account")
	}
}

func TestLocateQuarkUploadOpensFolderByFIDAndRefreshesTrail(t *testing.T) {
	accounts := NewAccounts(nil, nil)
	var listed []string
	transport := directoryTransport(func(r *http.Request) (*http.Response, error) {
		fid := r.URL.Query().Get("pdir_fid")
		listed = append(listed, fid)
		rows := []map[string]any{}
		switch fid {
		case "0":
			rows = append(rows, map[string]any{"fid": "target", "file_name": "新的目标名称", "dir": true, "pdir_fid": "0"})
		case "target":
			rows = append(rows, map[string]any{"fid": "folder", "file_name": "新项目", "dir": true, "pdir_fid": "target"})
		case "folder":
		default:
			return nil, fmt.Errorf("unexpected FID %s", fid)
		}
		return directoryReply(t, r, map[string]any{"status": 200, "code": 0, "data": map[string]any{"list": rows}})
	})
	session := AccountSession{State: LoggedIn, ID: "account", Quark: quark.New(quark.Credential{}, &http.Client{Transport: transport})}
	accounts.quark.current.Store(&session)
	folder := RemoteRef{Provider: Quark, ID: "folder"}
	job := newTransferJob(Quark, session, "项目", TransferUpload)
	job.ID = "job"
	job.Items = []TransferItem{{RelativePath: "项目", Directory: true, Remote: folder}}
	queue, err := newTransfers(&transferTestRecords{}, accounts, nil, nil, TransferConfig{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	queue.jobs = []transferRecord{{TransferJob: job, UploadTrail: []RemoteEntry{
		{Ref: RemoteRef{Provider: Quark, ID: "target"}, Name: "旧的目标名称", IsDirectory: true},
	}, Upload: &core.UploadRequest{ID: job.ID, Target: core.UploadTarget{Provider: string(Quark), AccountID: session.ID, FID: "target"}}}}
	location, err := queue.LocateUploadCloud(t.Context(), job.ID, "项目")
	if err != nil || !reflect.DeepEqual(listed, []string{"0", "target", "folder"}) {
		t.Fatalf("locate: err=%v, FIDs=%v", err, listed)
	}
	directory := NewDirectory(Quark)
	if !location.Apply(accounts, directory) || directory.Root() != folder || len(directory.Selection()) != 0 ||
		!directory.Loaded(folder) || directory.Trail()[0].Name != "新的目标名称" {
		t.Fatalf("wrong Quark target: %+v", directory.Location())
	}

	queue.jobs[0].UploadTrail = nil // Existing 5.0 record without known ancestors.
	listed = nil
	location, err = queue.LocateUploadCloud(t.Context(), job.ID, "项目")
	if err != nil || !location.Apply(accounts, directory) || directory.Root() != folder ||
		!reflect.DeepEqual(listed, []string{"target", "folder"}) {
		t.Fatalf("older record did not open by exact FID: err=%v FIDs=%v", err, listed)
	}
}
