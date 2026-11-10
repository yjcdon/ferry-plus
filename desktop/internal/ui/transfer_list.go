package ui

import (
	"cmp"
	"fmt"
	"runtime"
	"slices"
	"strings"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

type transferView struct {
	direction      string
	list           ui.ListState
	selection      ui.Selection[string]
	focus          int
	detailID       string
	scrollToID     string
	page           int
	problem        string
	sourceTarget   uploadSourceTarget
	sourceProblem  string
	sourceChecking bool
	remove         []string
	confirmRemove  bool
}

// AttachTransfers connects the persisted job coordinator to the workspace.
func (w *Workspace) AttachTransfers(transfers *app.Transfers) {
	w.jobs = transfers
	w.transfer.direction = "全部"
	w.transfer.focus = -1
	w.transfer.list.Selected = &w.transfer.focus
	w.transfer.list.Selection = &w.transfer.selection
	w.TransfersChanged()
}

func (w *Workspace) filteredTransfers() []app.TransferJob {
	if w.jobs == nil {
		return nil
	}
	query := strings.ToLower(strings.TrimSpace(w.transferSearch))
	jobs := w.jobs.Snapshot()
	jobs = slices.DeleteFunc(jobs, func(job app.TransferJob) bool {
		if !w.allProviders && string(job.Provider) != w.preferences.RecentProvider {
			return true
		}
		if w.transfer.direction == "上传" && job.Direction != app.TransferUpload ||
			w.transfer.direction == "下载" && job.Direction != app.TransferDownload {
			return true
		}
		return query != "" && !strings.Contains(strings.ToLower(job.Title), query) &&
			!strings.Contains(strings.ToLower(job.AccountName), query)
	})
	slices.SortStableFunc(jobs, func(a, b app.TransferJob) int {
		return b.CreatedAt.Compare(a.CreatedAt)
	})
	return jobs
}

func matchesTransferPage(job app.TransferJob, index int) bool {
	switch index {
	case 1:
		return job.State == app.TransferQueued || job.State == app.TransferWaitingAccount ||
			job.State == app.TransferRunning || job.State == app.TransferPaused
	case 2:
		return job.State == app.TransferCompleted
	case 3:
		return job.State == app.TransferFailed || job.State == app.TransferNeedsCheck
	default:
		return true
	}
}

func (w *Workspace) visibleTransfers(jobs []app.TransferJob, index int) []app.TransferJob {
	visible := slices.Clone(jobs)
	return slices.DeleteFunc(visible, func(job app.TransferJob) bool {
		return !matchesTransferPage(job, index)
	})
}

func (w *Workspace) transferRows(c *ui.Context, jobs []app.TransferJob, index int) {
	if w.jobs == nil {
		w.transferLanding(c, index)
		return
	}
	state := &w.transfer
	visible := w.visibleTransfers(jobs, index)
	if state.problem != "" {
		ui.Text(c, state.problem).Padding(8, 12).TextColor(c.Theme().Danger)
	}
	if len(visible) == 0 {
		w.transferLanding(c, index)
		return
	}

	if state.scrollToID != "" {
		if row := slices.IndexFunc(visible, func(job app.TransferJob) bool { return job.ID == state.scrollToID }); row >= 0 {
			state.list.ScrollIntoView(row)
			state.focus, state.scrollToID = row, ""
		}
	}
	state.list.Key = func(i int) any { return visible[i].ID }
	state.list.Label = func(i int) string { return visible[i].Title }
	list := ui.List(c, &state.list, len(visible), func(i int) {
		w.transferRow(c, visible[i])
	}).Grow(1).MinHeight(0)
	if list.Submitted() && state.focus >= 0 && state.focus < len(visible) {
		w.preferences.DetailsOpen = false
		width, _ := c.Size()
		w.toggleDetails(width)
		w.window.Invalidate()
	}
	w.transferSummary(c, visible)
}

func (w *Workspace) transferRow(c *ui.Context, job app.TransferJob) {
	ui.Row(c).Padding(10, 12).Gap(12).AlignItems(ui.Center).
		ContextMenu(func(m *ui.Menu) { w.taskMenu(m, job) }).Children(func() {
		ui.Column(c).Grow(1).MinWidth(0).Gap(5).Children(func() {
			ui.Text(c, job.Title).Bold().SingleLine().Tooltip(job.Title)
			ui.Text(c, providerTitle(string(job.Provider))+" · "+job.StatusText()).
				TextColor(c.Theme().TextMuted).SingleLine()
			if job.DuplicateOf != "" {
				ui.Text(c, "已有相同内容的上传").TextColor(c.Theme().TextMuted)
			}
			if job.Total > 0 {
				ui.Progress(c, min(1, float64(job.Done)/float64(job.Total))).
					Label("传输进度").FillWidth()
			}
		})
		if job.BytesPerSecond > 0 {
			ui.Text(c, fileSize(job.BytesPerSecond)+"/s").SingleLine()
		}
		if job.DuplicateOf != "" && ui.Button(c, "查看原任务").Clicked() {
			w.locateDuplicate(job.DuplicateOf)
		}
		label, command := w.primaryTransferAction(job)
		if command != nil && ui.Button(c, label).Disabled(job.Stopping).Clicked() {
			w.transferCommand(command, job.ID)
		}
		ui.MenuButton(c, "更多", func(m *ui.Menu) { w.taskMenu(m, job) }).Label(job.Title + " 的操作")
	})
}

func (w *Workspace) primaryTransferAction(job app.TransferJob) (string, func(string) error) {
	switch job.State {
	case app.TransferRunning, app.TransferQueued, app.TransferWaitingAccount:
		return "暂停", w.jobs.Pause
	case app.TransferPaused:
		if job.DuplicateOf != "" {
			return "仍然上传", w.jobs.Resume
		}
		return "继续", w.jobs.Resume
	case app.TransferFailed, app.TransferNeedsCheck:
		if !job.CancellationRequested {
			return "重试", w.jobs.RetryFailed
		}
		if job.State == app.TransferNeedsCheck && job.Direction == app.TransferUpload {
			return "核对云端结果", func(id string) error {
				return w.jobs.ReconcileCanceledUpload(w.ctx, id)
			}
		}
		return "", nil
	default:
		return "", nil
	}
}

func (w *Workspace) taskMenu(m *ui.Menu, job app.TransferJob) {
	if job.DuplicateOf != "" && m.Item("查看原任务").Chosen() {
		w.locateDuplicate(job.DuplicateOf)
	}
	if label, command := w.primaryTransferAction(job); command != nil && m.Item(label).Disabled(job.Stopping).Chosen() {
		w.transferCommand(command, job.ID)
	}
	if job.Direction == app.TransferUpload && job.State == app.TransferQueued &&
		m.Item("优先上传").Chosen() {
		w.transferCommand(w.jobs.Prioritize, job.ID)
	}
	if job.Direction == app.TransferUpload && !terminalTransfer(job.State) &&
		m.Item("取消上传").Disabled(job.Stopping).Chosen() {
		w.transferCommand(w.jobs.Cancel, job.ID)
	}
	if job.State != app.TransferNeedsCheck && terminalTransfer(job.State) && m.Item("移除任务记录").Chosen() {
		w.transfer.remove = []string{job.ID}
		w.transfer.confirmRemove = true
	}
}

func (w *Workspace) locateDuplicate(id string) {
	w.transfer.problem = ""
	if !w.selectTransfer(id) {
		w.transfer.problem = "原上传任务已移除。可选择仍然上传。"
	}
}

func terminalTransfer(state app.TransferState) bool {
	return state == app.TransferCompleted || state == app.TransferFailed || state == app.TransferCanceled || state == app.TransferNeedsCheck
}

func (w *Workspace) transferCommand(command func(string) error, id string) {
	w.transfer.problem = ""
	go func() {
		err := command(id)
		w.window.Update(func() {
			if err != nil {
				w.transfer.problem = err.Error()
			}
		})
	}()
}

func (w *Workspace) transferRemoveDialog(c *ui.Context) {
	if !w.transfer.confirmRemove {
		return
	}
	ids := w.transfer.remove
	if ui.AlertDialog(c, &w.transfer.confirmRemove, "移除任务记录？",
		fmt.Sprintf("将移除 %d 条传输记录。", len(ids)), "取消", "移除") == 1 {
		for _, id := range ids {
			w.transferCommand(w.jobs.Remove, id)
		}
	}
	if !w.transfer.confirmRemove {
		w.transfer.remove = nil
	}
}

func (w *Workspace) transferSummary(c *ui.Context, visible []app.TransferJob) {
	var done, total, speed int64
	var selected int
	for _, job := range visible {
		done += job.Done
		total += job.Total
		speed += job.BytesPerSecond
		if w.transfer.selection.Has(job.ID) {
			selected++
		}
	}
	ui.Toolbar(c, func() {
		ui.Textf(c, "%d 个任务", len(visible))
		if selected > 0 {
			ui.Textf(c, "已选择 %d 个传输任务", selected)
		}
		ui.Spacer(c)
		if total > 0 {
			ui.Text(c, fileSize(done)+" / "+fileSize(total)).SingleLine()
		}
		if speed > 0 {
			ui.Text(c, fileSize(speed)+"/s").SingleLine()
		}
	})
}

func (w *Workspace) transferDetails(c *ui.Context, jobs []app.TransferJob, index int) {
	selected := make([]app.TransferJob, 0, 1)
	for _, job := range w.visibleTransfers(jobs, index) {
		if w.transfer.selection.Has(job.ID) {
			selected = append(selected, job)
		}
	}
	if len(selected) == 0 {
		ui.Column(c).Fill().Center().Children(func() {
			ui.Text(c, "选择任务查看详情").TextColor(c.Theme().TextMuted)
		})
		return
	}
	if len(selected) > 1 {
		w.transferBatchDetails(c, selected)
		return
	}

	job := selected[0]
	state := &w.transfer
	if state.detailID != job.ID {
		state.detailID, state.page = job.ID, 0
	}
	const pageSize = 100
	maxPage := max(0, (len(job.Items)-1)/pageSize)
	state.page = min(state.page, maxPage)
	ui.Column(c).Fill().Children(func() {
		ui.Column(c).Padding(12).Gap(8).Children(func() {
			ui.Text(c, job.Title).FontSize(15).Bold()
			ui.Text(c, providerTitle(string(job.Provider))+" · "+job.StatusText()).TextColor(c.Theme().TextMuted)
			if job.Error != "" {
				ui.Text(c, job.Error).TextColor(c.Theme().Danger)
			}
			if job.Warning != "" {
				ui.Text(c, job.Warning).TextColor(c.Theme().TextMuted)
			}
			w.transferShareSource(c, job)
		})
		ui.Divider(c)
		ui.Scroll(c).Grow(1).Children(func() {
			start := state.page * pageSize
			for _, item := range job.Items[start:min(start+pageSize, len(job.Items))] {
				w.transferDetailItem(c, job, item)
			}
		})
		if maxPage > 0 {
			ui.Toolbar(c, func() {
				if ui.Button(c, "上一页").Disabled(state.page == 0).Clicked() {
					state.page--
				}
				ui.Textf(c, "%d / %d", state.page+1, maxPage+1)
				if ui.Button(c, "下一页").Disabled(state.page == maxPage).Clicked() {
					state.page++
				}
			})
		}
	})
}

func (w *Workspace) transferShareSource(c *ui.Context, job app.TransferJob) {
	if job.Direction != app.TransferDownload || job.ShareURL == "" {
		return
	}
	source, err := app.ParseShareInput(job.ShareURL, "")
	if err != nil || source.Provider != job.Provider {
		return
	}
	ui.Row(c).AlignItems(ui.Center).Gap(8).Children(func() {
		ui.Column(c).Grow(1).MinWidth(0).Children(func() {
			ui.Text(c, "分享链接").TextColor(c.Theme().TextMuted)
			ui.Text(c, source.URL).SingleLine().Tooltip(source.URL)
		})
		if ui.Button(c, "复制链接").Clicked() {
			go mygo.Clipboard.WriteText(source.URL)
		}
	})
}

func (w *Workspace) transferDetailItem(c *ui.Context, job app.TransferJob, item app.TransferItem) {
	target := uploadSourceTarget{job.ID, item.RelativePath}
	sourceChecking := job.RebindingPath == item.RelativePath || w.transfer.sourceChecking && w.transfer.sourceTarget == target
	ui.Column(c.Key(item.RelativePath)).FillWidth().Padding(6, 12).Gap(4).Children(func() {
		ui.Text(c, item.RelativePath).SingleLine().Tooltip(item.RelativePath)
		ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
			status := cmp.Or(item.Error, "等待传输")
			switch {
			case item.Error != "":
			case item.Skipped:
				status = "已跳过"
			case item.Verified:
				status = "已校验"
			case item.Complete:
				status = "已完成"
			case job.State == app.TransferCanceled:
				status = "已取消"
				if item.Remote.ID != "" {
					status = "已保留在网盘"
				}
			}
			ui.Text(c, status).TextColor(c.Theme().TextMuted).Grow(1).SingleLine().Tooltip(status)
			if item.LocalPath != "" {
				label := "在资源管理器中显示"
				if runtime.GOOS == "darwin" {
					label = "在访达中显示"
				}
				if ui.Button(c, "定位").Label(label).Clicked() {
					w.transferCommand(platform.RevealLocalItem, item.LocalPath)
				}
			}
		})
		if item.Error != "" && ui.Button(c, "复制错误").Clicked() {
			go mygo.Clipboard.WriteText(item.Error)
		}
		if job.Direction == app.TransferUpload && (job.State == app.TransferPaused || job.State == app.TransferFailed) && item.CanRebind {
			if ui.Button(c, "重新选择源文件").Disabled(job.Stopping || w.transfer.sourceChecking || w.chooser != nil).Clicked() {
				w.chooseReplacementUploadSource(target)
			}
		}
		if sourceChecking {
			ui.Text(c, "正在检查文件").TextColor(c.Theme().TextMuted)
		}
		if w.transfer.sourceTarget == target && w.transfer.sourceProblem != "" {
			ui.Text(c, w.transfer.sourceProblem).TextColor(c.Theme().Danger)
		}
	})
}
