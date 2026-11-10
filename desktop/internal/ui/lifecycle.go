package ui

import (
	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

// PrepareQuit closes transient interactions before the app waits for workers.
func (w *Workspace) PrepareQuit(done func()) {
	w.quitting, w.quitReady = true, done
	if w.chooser != nil {
		w.chooser()
		w.chooser = nil
	}
	if w.share != nil {
		w.share.cancel()
		w.share.releaseBrowser()
		w.share, w.shareOpen = nil, false
	}
	w.download, w.downloadOpen = nil, false
	w.confirmDirectoryDelete, w.confirmLogout, w.transfer.confirmRemove = false, false, false
	w.directoryDelete = nil

	for _, window := range w.loginWindows {
		window.Close()
	}
	if w.settingsWindow != nil {
		w.settingsWindow.Close()
	}
	w.finishPrepareQuit()
	w.window.Invalidate()
}

func (w *Workspace) finishPrepareQuit() {
	if w.quitReady == nil || len(w.loginWindows) != 0 || w.settingsWindow != nil {
		return
	}
	done := w.quitReady
	w.quitReady = nil
	done()
}

func (w *Workspace) quitNotice(c *ui.Context) {
	if w.quitting {
		shown := true
		ui.Modal(c, &shown, func() {
			ui.Text(c, "正在保存传输进度").Bold()
		})
	}
}

// DetectCopiedLink is called on app activation. The platform reports a stable
// sequence only after checking that automatic clipboard reading is allowed.
func (w *Workspace) DetectCopiedLink() {
	if w.quitting || !w.settings.Values().DetectsCopiedLinks || w.shareOpen ||
		w.downloadOpen || w.confirmDirectoryDelete || w.confirmLogout || !w.window.IsVisible() {
		return
	}
	w.readShareClipboard(func(link app.ShareLink, changed bool) {
		if !changed || link.URL == "" || w.quitting || !w.window.IsVisible() ||
			!w.settings.Values().DetectsCopiedLinks {
			return
		}
		for _, job := range w.jobs.Snapshot() {
			if job.ShareURL == link.URL {
				return
			}
		}
		w.openSharePrompt(link)
	})
}

func (w *Workspace) readShareClipboard(done func(app.ShareLink, bool)) {
	platform.CopiedShareText(w.ctx, w.clipboardSequence, func(text string, sequence uint64, changed bool) {
		if changed {
			w.clipboardSequence = sequence
			w.clipboardLink, _ = app.ParseShareInput(text, "")
		}
		done(w.clipboardLink, changed)
	})
}

// TransfersChanged observes saved terminal states and sends background notices
// without making system notification permission part of a job's result.
func (w *Workspace) TransfersChanged() {
	jobs := w.jobs.Snapshot()
	states := make(map[string]app.TransferState, len(jobs))
	for _, job := range jobs {
		states[job.ID] = job.State
		if w.quitting || job.Stopping || w.notifiedStates[job.ID] == job.State ||
			w.notifiedStates == nil || w.window.IsFocused() {
			continue
		}
		title := ""
		if job.State == app.TransferCompleted {
			title = "下载完成"
			if job.Direction == app.TransferUpload {
				title = "上传完成"
			}
		} else if job.Direction == app.TransferUpload && job.State == app.TransferFailed {
			title = job.StatusText()
		}
		if title != "" && mygo.NotificationsSupported() {
			notice := mygo.NewNotification(mygo.NotificationOptions{
				ID: job.ID, Title: title, Body: providerTitle(string(job.Provider)) + " · " + job.Title,
			})
			go func() { _ = notice.ShowContext(w.ctx) }()
		}
	}
	w.notifiedStates = states
}

// ShowTransfer brings the exact notification task into the visible list.
func (w *Workspace) ShowTransfer(id string) {
	w.window.Update(func() { w.selectTransfer(id) })
}

func (w *Workspace) selectTransfer(id string) bool {
	if w.quitting || w.jobs == nil {
		return false
	}
	for _, job := range w.jobs.Snapshot() {
		if job.ID == id {
			w.preferences.Page, w.allProviders = all, true
			w.transferSearch, w.transfer.direction = "", "全部"
			w.transfer.selection.Clear()
			w.transfer.selection.Add(id)
			w.transfer.scrollToID = id
			w.preferences.DetailsOpen = true
			return true
		}
	}
	return false
}
