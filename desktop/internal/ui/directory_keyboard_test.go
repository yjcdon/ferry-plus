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

func TestInlineRenameWaitsForCompositionBeforeSubmit(t *testing.T) {
	entry := app.RemoteEntry{
		Ref:  app.RemoteRef{Provider: app.Baidu, ID: "13", Path: "/原名"},
		Name: "原名",
	}
	f := newDirectoryView(app.Baidu, app.DirectoryLocation{})
	edit := &directoryEdit{
		selection: app.DirectorySelection{Items: []app.DirectoryItem{{Entry: entry}}},
		text:      entry.Name, fresh: true,
	}
	f.edit = edit
	workspace := NewWorkspace(Preferences{})
	workspace.window = &mygo.Window{}
	workspace.ctx = t.Context()
	workspace.accounts = app.NewAccounts(nil, nil)
	window := ui.NewTester(func(c *ui.Context) { workspace.directoryNameCell(c, f, entry) }, 380, 100)
	window.Frame()
	window.Compose("xinming", 7)
	window.Key(0, ui.KeyEnter)
	if f.edit != edit || edit.problem != "" || f.busy {
		t.Fatalf("组合输入中的 Enter 提交了重命名: %+v", edit)
	}
	window.Key(ui.Cmd, ui.KeyA)
	window.Compose("xinming", 7)
	window.Type("新名/")
	window.Key(0, ui.KeyEnter)
	if f.edit != edit || edit.text != "新名/" || edit.problem != "包含非法字符" || f.busy {
		t.Fatalf("候选提交后的 Enter 未按已提交文本校验: %+v", edit)
	}
	window.Key(0, ui.KeyEscape)
	if f.edit != nil {
		t.Fatal("结束组合输入后，Escape 应退出行内命名")
	}
}

func TestDirectoryF2OpensInlineRenameAndEscapeCancels(t *testing.T) {
	folder := app.RemoteEntry{
		Ref:  app.RemoteRef{Provider: app.Baidu, ID: "11", Path: "/项目资料"},
		Name: "项目资料", IsDirectory: true,
	}
	f := newDirectoryView(app.Baidu, app.DirectoryLocation{AccountID: "sample", Trail: []app.RemoteEntry{folder}})
	client := baidu.New(baidu.Credential{}, &http.Client{Transport: keyboardDirectoryTransport{}})
	defer client.Revoke()
	f.directory.SetSession(app.AccountSession{State: app.LoggedIn, ID: "sample", Baidu: client})
	request := f.directory.Refresh()
	if request == nil || !f.directory.Apply(request, request.Fetch(t.Context())) {
		t.Fatal("未加载重命名样本")
	}
	workspace := NewWorkspace(Preferences{})
	workspace.window = &mygo.Window{}
	focusRequested := true
	window := ui.NewTester(func(c *ui.Context) {
		workspace.directoryTable(c, f, f.directory.Roots())
		if focusRequested && f.outline.List.Focus(c) {
			focusRequested = false
		}
	}, 640, 400)
	window.Frame()
	window.Key(0, ui.KeyDown)
	window.Key(0, ui.KeyF2)
	if f.edit == nil || f.edit.text != "子文件.txt" {
		t.Fatalf("F2 未打开焦点文件的行内重命名: %+v", f.edit)
	}
	window.Frame()
	window.Key(0, ui.KeyEscape)
	if f.edit != nil || f.busy || f.directory.Roots()[0].Name != "子文件.txt" {
		t.Fatal("Escape 应取消重命名并保留原文件名")
	}
}
