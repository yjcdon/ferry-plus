package ui

import (
	"fmt"
	"runtime"

	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
)

func transferCanRemove(job app.TransferJob) bool {
	return !job.Stopping && !job.RemovalPending && (job.State == app.TransferCompleted ||
		job.State == app.TransferCanceled || job.State == app.TransferFailed && !job.CancellationRequested)
}

func transferCanTrash(job app.TransferJob) bool {
	return !job.Stopping && (job.State == app.TransferCompleted || job.State == app.TransferFailed) &&
		job.HasLocalDownloads()
}

func transferRemovalTargets(selected []app.TransferJob) (remove, trash []app.TransferJob) {
	allDownloads := true
	for _, job := range selected {
		allDownloads = allDownloads && job.Direction == app.TransferDownload
		if transferCanRemove(job) {
			remove = append(remove, job)
		}
		if transferCanTrash(job) {
			trash = append(trash, job)
		}
	}
	if !allDownloads {
		trash = nil
	}
	return remove, trash
}

func (w *Workspace) transferRemovalMenu(m *ui.Menu, job app.TransferJob) {
	if transferCanRemove(job) && m.Item("移除任务记录").Chosen() {
		w.confirmTransferRemoval([]app.TransferJob{job}, false)
	}
	if transferCanTrash(job) {
		label := "移除并删除下载文件"
		if job.RemovalPending {
			label = "重试清理下载文件"
		}
		if m.Item(label).Chosen() {
			w.confirmTransferRemoval([]app.TransferJob{job}, true)
		}
	}
}

func (w *Workspace) confirmTransferRemoval(jobs []app.TransferJob, trash bool) {
	w.transfer.remove, w.transfer.trashDownloads, w.transfer.confirmRemove = jobs, trash, true
}

func (w *Workspace) transferRemoveDialog(c *ui.Context) {
	if !w.transfer.confirmRemove {
		return
	}
	jobs := w.transfer.remove
	title := fmt.Sprintf("移除 %d 个任务记录？", len(jobs))
	message, confirm := "已下载的文件将保留。", "移除记录"
	command := w.jobs.Remove
	if w.transfer.trashDownloads {
		title = fmt.Sprintf("移除 %d 个任务并删除下载文件？", len(jobs))
		message, confirm = "已下载的文件将移到"+transferTrashName()+"。", "移除并删除文件"
		command = w.jobs.RemoveAndTrash
	}
	if ui.AlertDialog(c, &w.transfer.confirmRemove, title, message, "取消", confirm) == 1 {
		w.transferBatchCommand(command, jobs)
	}
	if !w.transfer.confirmRemove {
		w.transfer.remove = nil
	}
}

func transferTrashName() string {
	if runtime.GOOS == "darwin" {
		return "废纸篓"
	}
	return "回收站"
}
