package ui

import (
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
)

func TestUploadCompletionInvalidatesOnlyItsAccountDirectory(t *testing.T) {
	for _, state := range []app.TransferState{
		app.TransferCompleted, app.TransferFailed, app.TransferCanceled, app.TransferNeedsCheck,
	} {
		t.Run(string(state), func(t *testing.T) {
			workspace := NewWorkspace(Preferences{})
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
