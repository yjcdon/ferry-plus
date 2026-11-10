package app

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"path"
	"slices"
	"strings"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
)

type directoryTransport func(*http.Request) (*http.Response, error)

func (fn directoryTransport) RoundTrip(r *http.Request) (*http.Response, error) { return fn(r) }

func directoryReply(t *testing.T, r *http.Request, value any) (*http.Response, error) {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return &http.Response{Request: r, StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(string(data)))}, nil
}

type baiduRow struct {
	ID        int    `json:"fs_id"`
	Path      string `json:"path"`
	Directory int    `json:"isdir"`
	Size      int64  `json:"size"`
	Modified  *int64 `json:"server_mtime,omitempty"`
}

func newDirectorySession(t *testing.T, id string, transport directoryTransport) AccountSession {
	t.Helper()
	cred, err := baidu.ParseCredential("BDUSS=stub; STOKEN=stub")
	if err != nil {
		t.Fatal(err)
	}
	return AccountSession{ID: id, State: LoggedIn, Baidu: baidu.New(cred, &http.Client{Transport: transport})}
}

func directoryList(t *testing.T, r *http.Request, rows []baiduRow) (*http.Response, error) {
	t.Helper()
	if rows == nil {
		rows = []baiduRow{}
	}
	return directoryReply(t, r, map[string]any{"errno": 0, "list": rows})
}

func TestDirectoryNavigatesSearchesAndKeepsOneSelection(t *testing.T) {
	directories := map[string][]baiduRow{
		"/":       {{ID: 1, Path: "/文件10", Directory: 1}, {ID: 2, Path: "/文件2", Directory: 1}, {ID: 4, Path: "/文档.txt", Size: 12}},
		"/文件2":    {{ID: 3, Path: "/文件2/目录", Directory: 1}},
		"/文件2/目录": {{ID: 5, Path: "/文件2/目录/内容.txt", Size: 20}},
	}
	var calls []string
	transport := directoryTransport(func(r *http.Request) (*http.Response, error) {
		parent := r.URL.Query().Get("dir")
		calls = append(calls, parent)
		return directoryList(t, r, directories[parent])
	})
	session := newDirectorySession(t, "account", transport)
	directory := NewDirectory(Baidu)
	directory.SetSession(session)
	run := func(request *DirectoryRequest) {
		t.Helper()
		if request == nil || !directory.Apply(request, request.Fetch(context.Background())) {
			t.Fatal("could not apply current request")
		}
	}
	run(directory.Refresh())
	roots := directory.Roots()
	if len(roots) != 3 || roots[0].Name != "文件2" || roots[1].Name != "文件10" || roots[2].IsDirectory {
		t.Fatalf("wrong natural ordering: %+v", roots)
	}
	if !slices.Equal(calls, []string{"/"}) {
		t.Fatal("initial root load read unopened directories")
	}
	folder := roots[0].Ref
	run(directory.Expand(folder))
	child := directory.Children(folder)[0].Ref
	run(directory.Expand(child))
	file := directory.Children(child)[0].Ref
	directory.SetSelection([]RemoteRef{file, folder})
	if !slices.Equal(directory.Selection(), []RemoteRef{folder}) {
		t.Fatal("parent and child became duplicate operation targets")
	}
	directory.SetSelection([]RemoteRef{file})
	directory.Collapse(folder)
	if len(directory.Selection()) != 0 {
		t.Fatal("a hidden child stayed explicitly selected")
	}
	if again := directory.Expand(folder); again != nil {
		t.Fatal("reopening a loaded directory fetched unnecessarily")
	}
	directory.SetSelection([]RemoteRef{file})
	run(directory.Refresh())
	if !slices.Equal(directory.Selection(), []RemoteRef{file}) || !directory.IsExpanded(child) {
		t.Fatal("refresh lost surviving focus scope or expansion")
	}
	directory.SetQuery(" 文档 ")
	if len(directory.Roots()) != 1 || directory.Roots()[0].Name != "文档.txt" || len(directory.Selection()) != 0 {
		t.Fatal("search should filter only direct children and remove invisible selection")
	}
	directory.SetQuery("")
	if !directory.Enter(child) || directory.Root() != child || !directory.CanGoUp() {
		t.Fatal("enter did not establish true ancestors")
	}
	run(directory.Refresh())
	if !directory.Up() || directory.Root() != folder {
		t.Fatal("go up did not restore exact parent")
	}

	location := directory.Location()
	swapped := newDirectorySession(t, "account", transport)
	directory.SetSession(swapped)
	if directory.Root() != folder {
		t.Fatal("new client for the same account lost the location")
	}
	reopened := NewDirectory(Baidu)
	reopened.RestoreLocation(location)
	reopened.SetSession(session)
	if reopened.Root() != folder {
		t.Fatal("matching saved location did not restore")
	}
	reopened.SetSession(newDirectorySession(t, "other", transport))
	if reopened.Root() != Baidu.RootRef() {
		t.Fatal("different account inherited a remote location")
	}
}

func TestDirectoryRejectsStaleResultsAndKeepsLastGoodListOnFailure(t *testing.T) {
	var fail bool
	transport := directoryTransport(func(r *http.Request) (*http.Response, error) {
		if fail {
			return nil, errors.New("offline")
		}
		return directoryList(t, r, []baiduRow{{ID: 1, Path: "/folder", Directory: 1}})
	})
	session := newDirectorySession(t, "account", transport)
	directory := NewDirectory(Baidu)
	directory.SetSession(session)
	request := directory.Refresh()
	result := request.Fetch(context.Background())
	directory.SetSession(newDirectorySession(t, "account", transport))
	if directory.Apply(request, result) || directory.Loaded(directory.Root()) {
		t.Fatal("previous session published stale data")
	}

	request = directory.Refresh()
	directory.Apply(request, request.Fetch(context.Background()))
	folder := directory.Roots()[0].Ref
	fail = true
	request = directory.Refresh()
	directory.Apply(request, request.Fetch(context.Background()))
	if !directory.Loaded(directory.Root()) || directory.LoadError(directory.Root()) == nil || directory.Roots()[0].Ref != folder {
		t.Fatal("refresh failure replaced valid visible rows")
	}

	fail = false
	request = directory.Refresh()
	result = request.Fetch(context.Background())
	if !directory.Enter(folder) {
		t.Fatal("could not enter preserved directory")
	}
	if directory.Apply(request, result) || directory.Loaded(directory.Root()) {
		t.Fatal("previous root published stale data")
	}
}

func TestDirectorySortMissingModifiedAndStableIdentity(t *testing.T) {
	epoch := int64(100)
	directory := NewDirectory(Baidu)
	directory.SetSession(newDirectorySession(t, "account", func(r *http.Request) (*http.Response, error) {
		return directoryList(t, r, []baiduRow{{ID: 3, Path: "/a", Size: 4}, {ID: 2, Path: "/b", Size: 6, Modified: &epoch}, {ID: 1, Path: "/folder", Directory: 1}})
	}))
	req := directory.Refresh()
	directory.Apply(req, req.Fetch(context.Background()))
	for _, desc := range []bool{false, true} {
		directory.SetSort(SortModified, desc)
		rows := directory.Roots()
		if len(rows) != 3 || !rows[0].IsDirectory || path.Base(rows[1].Ref.Path) != "b" {
			t.Fatal("missing modified date should stay last in either direction")
		}
	}
}
