package app

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
)

func TestDirectoryMutationKeepsFrozenTargetsAndPartialFailures(t *testing.T) {
	ctx := context.Background()
	rows := []baiduRow{{ID: 1, Path: "/a", Size: 12}, {ID: 2, Path: "/b", Size: 14}, {ID: 3, Path: "/未命名文件夹", Directory: 1}}
	writes := 0
	accounts := NewAccounts(nil, nil)
	transport := directoryTransport(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/api/list":
			return directoryList(t, r, rows)
		case "/rest/2.0/pcs/file":
			writes++
			switch r.URL.Query().Get("method") {
			case "mkdir":
				p := r.URL.Query().Get("path")
				if p != "/未命名文件夹 2" {
					t.Fatalf("wrong new folder path: %s", p)
				}
				rows = append(rows, baiduRow{ID: 4, Path: p, Directory: 1})
				return directoryReply(t, r, map[string]any{"fs_id": 4, "path": p})
			case "delete":
				if err := r.ParseMultipartForm(1024); err != nil {
					t.Fatal(err)
				}
				var payload struct{ List []struct{ Path string } }
				if err := json.Unmarshal([]byte(r.FormValue("param")), &payload); err != nil || len(payload.List) != 1 {
					t.Fatalf("unexpected deletion payload: %v", err)
				}
				if payload.List[0].Path == "/b" {
					return directoryReply(t, r, map[string]any{"error_code": 31064})
				}
				rows = slices.DeleteFunc(rows, func(row baiduRow) bool { return row.Path == payload.List[0].Path })
				return directoryReply(t, r, map[string]any{"error_code": 0})
			}
		}
		t.Fatalf("unexpected endpoint %s", r.URL.Path)
		return nil, errors.New("unexpected endpoint")
	})
	session := newDirectorySession(t, "account", transport)
	accounts.baidu.current.Store(&session)
	directory := NewDirectory(Baidu)
	directory.SetSession(session)
	req := directory.Refresh()
	directory.Apply(req, req.Fetch(ctx))
	target, ok := directory.Target(directory.Root())
	if !ok {
		t.Fatal("loaded directory did not make a valid target")
	}
	created, err := target.Create(ctx, accounts, directory.DefaultFolderName())
	if err != nil || !directory.ApplyCreated(target, created) || directory.Selection()[0] != created.Ref {
		t.Fatalf("could not insert and focus creation: %v", err)
	}

	first := RemoteRef{Provider: Baidu, ID: "1", Path: "/a"}
	second := RemoteRef{Provider: Baidu, ID: "2", Path: "/b"}
	selection, ok := directory.FreezeSelection([]RemoteRef{first, second, first})
	if !ok || len(selection.Items) != 2 {
		t.Fatal("duplicate deletion targets were not removed")
	}

	result := selection.Trash(ctx, accounts)
	if len(result.Removed) != 1 || result.Removed[0].Entry.Ref != first ||
		len(result.Failures) != 1 || result.Failures[0].Entry.Ref != second || !errors.Is(result.Failures[0].Err, baidu.ErrAccessDenied) {
		t.Fatalf("wrong partial deletion result: %+v", result)
	}
	if !directory.ApplyTrash(selection, result) {
		t.Fatal("could not publish deletion receipt")
	}
	if _, ok := directory.Entry(first); ok {
		t.Fatal("confirmed deletion remained visible")
	}
	if _, ok := directory.Entry(second); !ok {
		t.Fatal("unconfirmed deletion removed a row")
	}

	replaced := newDirectorySession(t, "account", transport)
	accounts.baidu.current.Store(&replaced)
	if _, err := target.Create(ctx, accounts, "stale"); !errors.Is(err, ErrDirectorySessionChanged) || writes != 3 {
		t.Fatalf("frozen target wrote to replacement session: %v, writes %d", err, writes)
	}
}

func TestDirectoryRenameChecksExactSiblingAndConfirmsOnce(t *testing.T) {
	ctx := context.Background()
	rows := []baiduRow{{ID: 1, Path: "/a", Size: 12}, {ID: 2, Path: "/é", Size: 14}}
	writes := 0
	accounts := NewAccounts(nil, nil)
	transport := directoryTransport(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/api/list":
			return directoryList(t, r, rows)
		case "/api/gettemplatevariable":
			return directoryReply(t, r, map[string]any{"errno": 0, "result": map[string]string{"bdstoken": "test"}})
		case "/api/user/getinfo":
			return directoryReply(t, r, map[string]any{"errno": 0, "records": []map[string]int{{"uk": 1}}})
		case "/c/s/login":
			return directoryReply(t, r, map[string]string{"error_code": "1"})
		case "/api/filemanager":
			writes++
			if err := r.ParseForm(); err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(r.Form.Get("filelist"), `"newname":"updated"`) {
				t.Fatal("rename lost the confirmed name")
			}
			rows[0].Path = "/updated"
			return directoryReply(t, r, map[string]any{"errno": 0, "info": []map[string]any{{"errno": 0, "path": "/a"}}})
		}
		return nil, errors.New("unexpected endpoint")
	})
	session := newDirectorySession(t, "account", transport)
	accounts.baidu.current.Store(&session)
	directory := NewDirectory(Baidu)
	directory.SetSession(session)
	req := directory.Refresh()
	directory.Apply(req, req.Fetch(ctx))
	original := RemoteRef{Provider: Baidu, ID: "1", Path: "/a"}
	directory.SetSelection([]RemoteRef{original})
	selection, ok := directory.FreezeSelection([]RemoteRef{original})
	if !ok {
		t.Fatal("could not freeze rename")
	}
	if _, err := selection.Rename(ctx, accounts, "e\u0301"); !errors.Is(err, ErrDirectoryNameExists) || writes != 0 {
		t.Fatalf("normalized sibling collision reached provider: %v", err)
	}
	updated, err := selection.Rename(ctx, accounts, "updated")
	if err != nil || writes != 1 || updated.Ref.ID != original.ID || !directory.ApplyRenamed(selection, updated) ||
		!slices.Equal(directory.Selection(), []RemoteRef{updated.Ref}) {
		t.Fatalf("verified rename did not preserve the row's selection: %v", err)
	}
}

func TestCreateBaiduDirectoryRejectsReplacedParent(t *testing.T) {
	accounts := NewAccounts(nil, nil)
	parentID, writes := 17, 0
	transport := directoryTransport(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/api/list":
			return directoryList(t, r, []baiduRow{{ID: parentID, Path: "/parent", Directory: 1}})
		case "/rest/2.0/pcs/file":
			writes++
			return directoryReply(t, r, map[string]any{"fs_id": 19, "path": "/parent/new"})
		default:
			t.Fatalf("unexpected endpoint %s", r.URL.Path)
			return nil, errors.New("unexpected endpoint")
		}
	})
	session := newDirectorySession(t, "account", transport)
	accounts.baidu.current.Store(&session)
	target := DirectoryTarget{Ref: RemoteRef{Provider: Baidu, ID: "17", Path: "/parent"}, AccountID: session.ID, session: session}
	parentID = 18
	if _, err := target.Create(t.Context(), accounts, "new"); !errors.Is(err, ErrDirectoryEntryChanged) || writes != 0 {
		t.Fatalf("替换目录不应收到创建请求: %v，写入 %d 次", err, writes)
	}
	parentID = 17
	if created, err := target.Create(t.Context(), accounts, "new"); err != nil || created.Ref.ID != "19" || writes != 1 {
		t.Fatalf("原目录应成功创建一次: %+v，%v，写入 %d 次", created, err, writes)
	}
}
