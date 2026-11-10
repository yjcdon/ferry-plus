package ui

import (
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
)

type keyboardDirectoryTransport struct{}

func (keyboardDirectoryTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	body := `{"errno":0,"list":[]}`
	if req.URL.Query().Get("dir") == "/项目资料" {
		body = `{"errno":0,"list":[{"fs_id":13,"path":"/项目资料/子文件.txt","isdir":0,"size":10}]}`
	}
	return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body)), Request: req}, nil
}

func TestDirectoryParentShortcutWithoutSelectedRow(t *testing.T) {
	child := app.RemoteEntry{
		Ref:  app.RemoteRef{Provider: app.Baidu, ID: "11", Path: "/项目资料"},
		Name: "项目资料", IsDirectory: true,
	}
	f := newDirectoryView(app.Baidu, app.DirectoryLocation{AccountID: "sample", Trail: []app.RemoteEntry{child}})
	client := baidu.New(baidu.Credential{}, &http.Client{Transport: keyboardDirectoryTransport{}})
	defer client.Revoke()
	f.directory.SetSession(app.AccountSession{State: app.LoggedIn, ID: "sample", Baidu: client})
	request := f.directory.Refresh()
	if request == nil || !f.directory.Apply(request, request.Fetch(t.Context())) || f.directory.Root() != child.Ref {
		t.Fatal("未加载子目录样本")
	}
	workspace := NewWorkspace(Preferences{})
	workspace.window = &mygo.Window{}
	workspace.ctx = t.Context()
	workspace.accounts = app.NewAccounts(nil, nil)
	focusRequested := true
	window := ui.NewTester(func(c *ui.Context) {
		workspace.directoryTable(c, f, f.directory.Roots())
		if focusRequested && f.outline.List.Focus(c) {
			focusRequested = false
		}
	}, 640, 400)
	window.Frame()
	if f.focus != -1 || f.selection.Len() != 0 || focusRequested {
		t.Fatal("文件表应有焦点且未选中任何行")
	}
	window.Key(ui.Cmd, ui.KeyUp)
	if got := f.directory.Root(); got != app.Baidu.RootRef() {
		t.Fatalf("上一级快捷键未返回根目录: %+v", got)
	}
}
