package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"

	"io/fs"
	"net/http"
	"reflect"
	"strings"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/quark"
)

type shareTestStore struct {
	records map[string][]byte
	secrets map[string][]byte
}

func (s shareTestStore) Read(key string, value any) error {
	data, ok := s.records[key]
	if !ok {
		return fs.ErrNotExist
	}
	return json.Unmarshal(data, value)
}

func (s shareTestStore) Write(key string, value any) error {
	data, err := json.Marshal(value)
	if err == nil {
		s.records[key] = data
	}
	return err
}

func (s shareTestStore) Remove(key string) error {
	delete(s.records, key)
	return nil
}

func (s shareTestStore) ReadCredential(key string) ([]byte, error) {
	data, ok := s.secrets[key]
	if !ok {
		return nil, fs.ErrNotExist
	}
	return data, nil
}

func (s shareTestStore) WriteCredential(key string, data []byte) error {
	s.secrets[key] = data
	return nil
}

func (s shareTestStore) RemoveCredential(key string) error {
	delete(s.secrets, key)
	return nil
}

func TestShareInputAndExplicitCode(t *testing.T) {
	for _, fixture := range []struct {
		text, explicit string
		provider       Provider
		code           string
	}{
		{"链接 https://pan.baidu.com/s/1test123?pwd=a1B2 提取码：a1B2", "xY34", Baidu, "xY34"},
		{"链接：https://pan.quark.cn/s/test123 提取码：a1B2", "", Quark, "a1B2"},
	} {
		link, err := ParseShareInput(fixture.text, fixture.explicit)
		if err != nil || link.Provider != fixture.provider || link.Passcode != fixture.code || strings.Contains(link.URL, "?") {
			t.Fatalf("parsed link = %+v, %v", link, err)
		}
	}
	if _, err := ParseShareInput("https://pan.quark.cn/s/test", "too-long"); !errors.Is(err, ErrShareCode) {
		t.Fatalf("invalid explicit code: %v", err)
	}
}

func TestShareTransferResumesExistingReceiptAndConfinesCleanup(t *testing.T) {
	var ownedName string
	var opened, submitted, checked, removed int
	var wrongRoot, sourceChanged bool
	const sourceMD5 = "5d41402abc4b2a76b9719d911017c592"
	providerTransport := directoryTransport(func(r *http.Request) (*http.Response, error) {
		response := func(data any) (*http.Response, error) {
			return directoryReply(t, r, map[string]any{"status": 200, "code": 0, "data": data})
		}
		list := func(rows ...map[string]any) (*http.Response, error) {
			if len(rows) == 0 {
				rows = []map[string]any{}
			}
			return response(map[string]any{"list": rows})
		}
		file := func(id, name, parent, md5 string) map[string]any {
			return map[string]any{"fid": id, "file_name": name, "file": true, "size": 5, "pdir_fid": parent, "md5": md5, "share_fid_token": "entry-token"}
		}
		folder := func(id, name, parent string) map[string]any {
			return map[string]any{"fid": id, "file_name": name, "dir": true, "pdir_fid": parent, "share_fid_token": "directory-token"}
		}
		var body map[string]any
		if r.Method == http.MethodPost {
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				return nil, err
			}
		}
		switch r.URL.Path {
		case "/1/clouddrive/share/sharepage/token":
			opened++
			if body["pwd_id"] != "test123" || body["passcode"] != "a1B2" {
				return nil, fmt.Errorf("invalid share input: %v", body)
			}
			return response(map[string]string{"stoken": "session-token", "title": "示例分享"})
		case "/1/clouddrive/share/sharepage/detail":
			switch r.URL.Query().Get("pdir_fid") {
			case "0":
				return list(folder("source-dir", "目录", "publisher"))
			case "source-dir":
				if sourceChanged {
					return nil, errors.New("original share no longer available")
				}
				return list(file("source-file", "样本.txt", "source-dir", sourceMD5))
			}
		case "/1/clouddrive/file":
			if body["pdir_fid"] == "0" && strings.HasPrefix(body["file_name"].(string), shareOwnedPrefix) {
				ownedName = body["file_name"].(string)
				return response(map[string]string{"fid": "owned"})
			}
		case "/1/clouddrive/file/sort":
			switch r.URL.Query().Get("pdir_fid") {
			case "0":
				if ownedName == "" || removed > 0 {
					return list()
				}
				if wrongRoot {
					return list(folder("replacement", ownedName, "0"))
				}
				return list(folder("owned", ownedName, "0"))
			case "owned":
				return list(folder("saved-dir", "目录", "owned"))
			case "saved-dir":
				return list(file("saved-file", "样本.txt", "saved-dir", strings.Repeat("a", 32)))
			}
		case "/1/clouddrive/share/sharepage/save":
			submitted++
			if !reflect.DeepEqual(body["fid_list"], []any{"source-dir"}) ||
				!reflect.DeepEqual(body["fid_token_list"], []any{"directory-token"}) ||
				body["to_pdir_fid"] != "owned" || body["pdir_fid"] != "0" {
				return nil, fmt.Errorf("wrong save payload: %v", body)
			}
			return response(map[string]string{"task_id": "submitted-task"})
		case "/1/clouddrive/task":
			checked++
			if r.URL.Query().Get("task_id") != "submitted-task" {
				return nil, errors.New("queried unexpected receipt")
			}
			if checked == 1 {
				return nil, errors.New("connection lost")
			}
			return response(map[string]any{"status": 2, "task_id": "submitted-task"})
		case "/1/clouddrive/file/delete":
			if !reflect.DeepEqual(body["filelist"], []any{"owned"}) {
				return nil, fmt.Errorf("wrong cleanup target: %v", body)
			}
			removed++
			return response(nil)
		}
		return nil, fmt.Errorf("unexpected request %s", r.URL)
	})
	records := shareTestStore{make(map[string][]byte), make(map[string][]byte)}
	client := quark.New(quark.Credential{}, &http.Client{Transport: providerTransport})
	accounts := NewAccounts(records, nil)
	session := AccountSession{State: LoggedIn, ID: "account", Quark: client}
	accounts.quark.current.Store(&session)
	ctx := t.Context()
	link, err := ParseShareInput("https://pan.quark.cn/s/test123", "a1B2")
	if err != nil {
		t.Fatal(err)
	}
	browser, err := OpenShare(ctx, accounts, link)
	if err != nil {
		t.Fatal(err)
	}
	request := browser.Refresh()
	if !browser.Apply(request, request.Fetch(ctx)) || len(browser.Tree().Roots()) != 1 {
		t.Fatalf("root failed: %v", browser.Tree().LoadError(Quark.RootRef()))
	}
	parent := browser.Tree().Roots()[0].Ref
	request = browser.Expand(parent)
	if !browser.Apply(request, request.Fetch(ctx)) || len(browser.Tree().Children(parent)) != 1 {
		t.Fatalf("subdirectory failed: %v", browser.Tree().LoadError(parent))
	}
	browser.Tree().SetSelection([]RemoteRef{parent, browser.Tree().Children(parent)[0].Ref})
	selection, err := browser.Selection()
	if err != nil || len(selection.anchors) != 1 {
		t.Fatalf("selection = %+v, %v", selection.anchors, err)
	}
	browser.Close()
	if browser.Apply(request, request.Fetch(ctx)) {
		t.Fatal("closed share accepted stale page")
	}
	if err := newShareTransfer(records, accounts).Stage("download", selection, "/"); err != nil {
		t.Fatal(err)
	}
	if opened != 1 || submitted != 0 || ownedName != "" {
		t.Fatal("staging performed remote work")
	}
	if _, err := newShareTransfer(records, accounts).Resume(ctx, "download"); err == nil {
		t.Fatal("expected task-query transport failure")
	}
	if opened != 2 || submitted != 1 || checked != 1 || len(records.secrets) != 1 {
		t.Fatalf("submit=%d query=%d secrets=%d", submitted, checked, len(records.secrets))
	}
	for _, record := range records.records {
		for _, secret := range []string{"a1B2", "session-token", "directory-token", "entry-token"} {
			if strings.Contains(string(record), secret) {
				t.Fatalf("ordinary record exposed %s", secret)
			}
		}
	}
	sourceChanged = true
	result, err := newShareTransfer(records, accounts).Resume(ctx, "download")
	if err != nil || opened != 2 || submitted != 1 || checked != 2 || len(result.Items) != 1 || len(records.secrets) != 0 {
		t.Fatalf("resumed=%+v err=%v opened=%d submitted=%d checked=%d", result, err, opened, submitted, checked)
	}
	item := result.Items[0]
	if item.Entry.Ref.ID != "saved-file" || item.RelativePath != "目录/样本.txt" || item.Entry.MD5 != sourceMD5 {
		t.Fatalf("download identity and original digest were not preserved: %+v", item)
	}
	wrongRoot = true
	if err := result.Cleanup.Cleanup(ctx, session); !errors.Is(err, ErrShareTransferUnconfirmed) || removed != 0 {
		t.Fatalf("cleanup accepted same-named unrelated directory: %v, removed=%d", err, removed)
	}
	wrongRoot = false
	if err := result.Cleanup.Cleanup(ctx, session); err != nil || removed != 1 {
		t.Fatalf("exact cleanup failed: %v, removed=%d", err, removed)
	}
}

func TestBaiduShareChecksOwnedManifestAfterLostTransferResponse(t *testing.T) {
	const rawLink = "https://pan.baidu.com/s/1qYZEsSc"
	const filename = "示例.txt"
	var owned string
	submits := 0
	var settled bool
	transport := directoryTransport(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/s/1qYZEsSc":
			response, err := directoryReply(t, r, nil)
			response.Body.Close()
			response.Body = io.NopCloser(strings.NewReader(`<script>locals.mset({"loginstate":1,"bdstoken":"aaaa1111","shareid":"3003","share_uk":2002});</script>`))
			return response, err
		case "/share/list":
			return directoryList(t, r, []baiduRow{{ID: 1, Path: "/publisher/" + filename, Size: 5}})
		case "/api/list":
			switch r.URL.Query().Get("dir") {
			case "/":
				if owned == "" {
					return directoryList(t, r, nil)
				}
				return directoryList(t, r, []baiduRow{{ID: 10, Path: owned, Directory: 1}})
			case owned:
				if settled {
					return directoryList(t, r, []baiduRow{{ID: 100, Path: owned + "/" + filename, Size: 5}})
				}
				return directoryList(t, r, nil)
			}
		case "/rest/2.0/pcs/file":
			if r.URL.Query().Get("method") != "mkdir" {
				break
			}
			target := r.URL.Query().Get("path")
			if owned != "" {
				if target != owned {
					return nil, fmt.Errorf("unexpected path %s", target)
				}
				return directoryReply(t, r, map[string]any{"error_code": 31061})
			}
			owned = target
			return directoryReply(t, r, map[string]any{"fs_id": 10, "path": owned})
		case "/share/transfer":
			if err := r.ParseForm(); err != nil {
				return nil, err
			}
			if r.Form.Get("fsidlist") != "[1]" || r.Form.Get("path") != owned {
				return nil, fmt.Errorf("wrong transfer payload: %v", r.Form)
			}
			submits++
			return nil, errors.New("response lost after submit")
		}
		return nil, fmt.Errorf("unexpected request %s", r.URL)
	})
	records := shareTestStore{make(map[string][]byte), make(map[string][]byte)}
	accounts := NewAccounts(records, nil)
	session := newDirectorySession(t, "baidu", transport)
	accounts.baidu.current.Store(&session)
	ctx := t.Context()
	link, err := ParseShareInput(rawLink, "")
	if err != nil {
		t.Fatal(err)
	}
	browser, err := OpenShare(ctx, accounts, link)
	if err != nil {
		t.Fatal(err)
	}
	defer browser.Close()
	request := browser.Refresh()
	browser.Apply(request, request.Fetch(ctx))
	browser.Tree().SelectAll()
	selection, err := browser.Selection()
	if err != nil {
		t.Fatal(err)
	}
	staging := newShareTransfer(records, accounts)
	if _, err := staging.Prepare(ctx, "baidu-job", selection, "/"); !errors.Is(err, ErrShareTransferUnconfirmed) || submits != 1 {
		t.Fatalf("lost response must persist the transfer intent: %v submits=%d", err, submits)
	}
	if _, err := staging.Resume(ctx, "baidu-job"); !errors.Is(err, ErrShareTransferUnconfirmed) || submits != 1 {
		t.Fatalf("missing result cannot resubmit: %v submits=%d", err, submits)
	}
	settled = true
	got, err := staging.Resume(ctx, "baidu-job")
	if err != nil || len(got.Items) != 1 || got.Items[0].Entry.Ref.ID != "100" || got.Items[0].RelativePath != filename || submits != 1 {
		t.Fatalf("verified completion must use account identity: %+v err=%v submits=%d", got, err, submits)
	}
}
