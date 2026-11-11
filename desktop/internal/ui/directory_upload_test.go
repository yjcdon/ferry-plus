package ui

import (
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
)

func TestUploadCompletionInvalidatesOnlyItsAccountDirectory(t *testing.T) {
	for _, state := range []app.TransferState{
		app.TransferCompleted, app.TransferFailed, app.TransferCanceled, app.TransferNeedsCheck,
	} {
		t.Run(string(state), func(t *testing.T) {
			workspace := NewWorkspace(Preferences{Page: all})
			baidu := newDirectoryView(app.Baidu, app.DirectoryLocation{})
			quark := newDirectoryView(app.Quark, app.DirectoryLocation{})
			baidu.directory.SetSession(app.AccountSession{State: app.LoggedIn, ID: "account"})
			quark.directory.SetSession(app.AccountSession{State: app.LoggedIn, ID: "account"})
			workspace.files = map[app.Provider]*directoryView{app.Baidu: baidu, app.Quark: quark}
			workspace.notifiedStates = map[string]app.TransferState{"upload": app.TransferRunning}
			job := app.TransferJob{ID: "upload", Provider: app.Baidu, AccountID: "account",
				Direction: app.TransferUpload, State: state}
			job.Stopping = true
			workspace.invalidateUploadDirectories([]app.TransferJob{job})
			if baidu.refreshPending {
				t.Fatal("等待 worker 收尾后再刷新目录")
			}
			job.Stopping = false
			workspace.invalidateUploadDirectories([]app.TransferJob{job})
			if !baidu.refreshPending || quark.refreshPending {
				t.Fatal("上传结束应只刷新该网盘账号的目录")
			}
			baidu.refreshPending = false
			workspace.notifiedStates[job.ID] = state
			workspace.invalidateUploadDirectories([]app.TransferJob{job})
			if baidu.refreshPending {
				t.Fatal("重复进度通知不应重复刷新目录")
			}
			workspace.notifiedStates[job.ID] = app.TransferRunning
			job.AccountID = "other-account"
			workspace.invalidateUploadDirectories([]app.TransferJob{job})
			if baidu.refreshPending {
				t.Fatal("其他账号的任务不能刷新当前账号目录")
			}
			job.AccountID = "account"
			job.Direction = app.TransferDownload
			workspace.invalidateUploadDirectories([]app.TransferJob{job})
			if baidu.refreshPending {
				t.Fatal("下载完成不应刷新远端目录")
			}
			job.Direction = app.TransferUpload
			workspace.notifiedStates = nil
			workspace.invalidateUploadDirectories([]app.TransferJob{job})
			if baidu.refreshPending {
				t.Fatal("启动读取历史任务不应触发刷新")
			}
		})
	}
}

// The completion event must start the fetch before another UI frame or click.
func TestUploadCompletionRefreshesVisibleDirectoryWithoutInput(t *testing.T) {
	target := app.RemoteEntry{
		Ref:  app.RemoteRef{Provider: app.Baidu, ID: "11", Path: "/上传测试"},
		Name: "上传测试", IsDirectory: true,
	}
	f := newDirectoryView(app.Baidu, app.DirectoryLocation{AccountID: "sample", Trail: []app.RemoteEntry{target}})
	requests := make(chan string, 1)
	client := baidu.New(baidu.Credential{}, &http.Client{Transport: uploadRefreshTransport{requests}})
	defer client.Revoke()
	f.directory.SetSession(app.AccountSession{State: app.LoggedIn, ID: "sample", Baidu: client})
	workspace := NewWorkspace(Preferences{})
	workspace.ctx = t.Context()
	workspace.window = &mygo.Window{}
	workspace.accounts = app.NewAccounts(nil, nil)
	workspace.files = map[app.Provider]*directoryView{app.Baidu: f}
	workspace.notifiedStates = map[string]app.TransferState{"upload": app.TransferRunning}

	workspace.invalidateUploadDirectories([]app.TransferJob{{
		ID: "upload", Provider: app.Baidu, AccountID: "sample",
		Direction: app.TransferUpload, State: app.TransferCompleted,
	}})
	if f.refreshPending || !f.directory.Loading(target.Ref) {
		t.Fatal("应在无需重绘或点击的情况下启动目录刷新")
	}
	select {
	case got := <-requests:
		if got != target.Ref.Path {
			t.Fatalf("目录刷新请求发往了 %q，预期 %q", got, target.Ref.Path)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("目录刷新未发起网络请求")
	}
}

type uploadRefreshTransport struct{ requests chan<- string }

func (t uploadRefreshTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	t.requests <- req.URL.Query().Get("dir")
	return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header),
		Body: io.NopCloser(strings.NewReader(`{"errno":0,"list":[]}`)), Request: req}, nil
}
