package ui

import (
	"fmt"
	"strings"

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
	var removable []string
	for _, job := range selected {
		if !job.Stopping && (job.State == app.TransferCompleted || job.State == app.TransferCanceled ||
			job.State == app.TransferFailed && !job.CancellationRequested) {
			removable = append(removable, job.ID)
		}
	}
	ui.Column(c).Fill().Center().Gap(8).Children(func() {
		ui.Textf(c, "已选择 %d 个传输任务", len(selected)).TextColor(c.Theme().TextMuted)
		if len(pause) > 0 && ui.Button(c, "暂停").Clicked() {
			w.transferBatchCommand(w.jobs.Pause, pause)
		}
		if len(resume) > 0 && ui.Button(c, "继续").Clicked() {
			w.transferBatchCommand(w.jobs.Resume, resume)
		}
		if len(removable) > 0 && ui.Button(c, "移除任务记录").Clicked() {
			w.transfer.remove, w.transfer.confirmRemove = removable, true
		}
	})
}
