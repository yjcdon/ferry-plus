package ui

import (
	"fmt"
	"strings"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
)

func (w *Workspace) transferBatchToolbar(c *ui.Context, visible []app.TransferJob) {
	pause, resume := w.transferBatchTargets(visible)
	label, icon, targets, command := "继续当前列表", resumeIcon, resume, w.jobs.Resume
	if len(pause) > 0 {
		label, icon, targets, command = "暂停当前列表", pauseIcon, pause, w.jobs.Pause
	}
	if workspaceToolbarButton(c, label, icon).Disabled(len(targets) == 0).Clicked() {
		w.transferBatchCommand(command, targets)
	}
}

func (w *Workspace) transferBatchTargets(jobs []app.TransferJob) (pause, resume []app.TransferJob) {
	for _, job := range jobs {
		if job.Stopping || job.CancellationRequested {
			continue
		}
		switch job.State {
		case app.TransferQueued, app.TransferWaitingAccount, app.TransferRunning:
			pause = append(pause, job)
		case app.TransferPaused:
			if job.DuplicateOf == "" && w.accounts != nil {
				session := w.accounts.Session(job.Provider)
				if session.State == app.LoggedIn && session.ID == job.AccountID {
					resume = append(resume, job)
				}
			}
		}
	}
	return pause, resume
}

// transferRetryTargets keeps batch retries within the same recoverable states as a single task.
func transferRetryTargets(jobs []app.TransferJob) []app.TransferJob {
	var retry []app.TransferJob
	for _, job := range jobs {
		if !job.Stopping && !job.CancellationRequested && !job.RemovalPending &&
			(job.State == app.TransferFailed || job.State == app.TransferNeedsCheck) {
			retry = append(retry, job)
		}
	}
	return retry
}

func prioritizedUploads(jobs []app.TransferJob) []app.TransferJob {
	var queued []app.TransferJob
	for _, job := range jobs {
		if job.Direction == app.TransferUpload && job.State == app.TransferQueued && !job.Stopping {
			queued = append(queued, job)
		}
	}
	return queued
}

func (w *Workspace) transferBatchCommand(command func(string) error, jobs []app.TransferJob) {
	w.transfer.problem = ""
	go func() {
		var problems []string
		for _, job := range jobs {
			if err := command(job.ID); err != nil {
				problems = append(problems, fmt.Sprintf("%s：%v", job.Title, err))
			}
		}
		w.window.Update(func() { w.transfer.problem = strings.Join(problems, "\n") })
	}()
}

func (w *Workspace) transferBatchDetails(c *ui.Context, selected []app.TransferJob) {
	pause, resume := w.transferBatchTargets(selected)
	retry := transferRetryTargets(selected)
	priority := prioritizedUploads(selected)
	remove, trash := transferRemovalTargets(selected)
	ui.Column(c).Fill().Center().Gap(8).Children(func() {
		ui.Textf(c, "已选择 %d 个传输任务", len(selected)).TextColor(c.Theme().TextMuted)
		if len(pause) > 0 && ui.Button(c, "暂停").Clicked() {
			w.transferBatchCommand(w.jobs.Pause, pause)
		}
		if len(resume) > 0 && ui.Button(c, "继续").Clicked() {
			w.transferBatchCommand(w.jobs.Resume, resume)
		}
		if len(retry) > 0 && ui.Button(c, "重试失败项").Clicked() {
			w.transferBatchCommand(w.jobs.RetryFailed, retry)
		}
		if len(priority) > 0 && ui.Button(c, "优先上传").Clicked() {
			w.transferBatchCommand(w.jobs.Prioritize, priority)
		}
		if text := transferErrorText(selected); text != "" && ui.Button(c, "复制错误").Clicked() {
			go mygo.Clipboard.WriteText(text)
		}
		if len(remove) > 0 && ui.Button(c, "移除任务记录").Clicked() {
			w.confirmTransferRemoval(remove, false)
		}
		if len(trash) > 0 && ui.Button(c, "移除并删除下载文件").Clicked() {
			w.confirmTransferRemoval(trash, true)
		}
	})
}

// taskSelectionMenu applies a row context menu to the visible selection when it contains that row.
func (w *Workspace) taskSelectionMenu(m *ui.Menu, clicked app.TransferJob, visible []app.TransferJob) {
	var selected []app.TransferJob
	if w.transfer.selection.Has(clicked.ID) {
		for _, job := range visible {
			if w.transfer.selection.Has(job.ID) {
				selected = append(selected, job)
			}
		}
	}
	if len(selected) < 2 {
		w.taskMenu(m, clicked)
		return
	}
	pause, resume := w.transferBatchTargets(selected)
	retry := transferRetryTargets(selected)
	priority := prioritizedUploads(selected)
	remove, trash := transferRemovalTargets(selected)
	if len(pause) > 0 && m.Item("暂停").Chosen() {
		w.transferBatchCommand(w.jobs.Pause, pause)
	}
	if len(resume) > 0 && m.Item("继续").Chosen() {
		w.transferBatchCommand(w.jobs.Resume, resume)
	}
	if len(retry) > 0 && m.Item("重试失败项").Chosen() {
		w.transferBatchCommand(w.jobs.RetryFailed, retry)
	}
	if len(priority) > 0 && m.Item("优先上传").Chosen() {
		w.transferBatchCommand(w.jobs.Prioritize, priority)
	}
	if text := transferErrorText(selected); text != "" && m.Item("复制错误").Chosen() {
		go mygo.Clipboard.WriteText(text)
	}
	if len(remove) > 0 && m.Item("移除任务记录").Chosen() {
		w.confirmTransferRemoval(remove, false)
	}
	if len(trash) > 0 && m.Item("移除并删除下载文件").Chosen() {
		w.confirmTransferRemoval(trash, true)
	}
}

func transferErrorText(jobs []app.TransferJob) string {
	var lines []string
	for _, job := range jobs {
		if job.Error != "" {
			lines = append(lines, job.Title+"："+job.Error)
		}
	}
	return strings.Join(lines, "\n")
}
