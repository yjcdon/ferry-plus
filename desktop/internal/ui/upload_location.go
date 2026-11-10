package ui

import (
	"context"
	"errors"
	"runtime"

	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
)

type uploadLocationView struct {
	target  uploadSourceTarget
	running bool
	problem string
}

func (w *Workspace) uploadLocationActions(c *ui.Context, target uploadSourceTarget, item app.TransferItem) {
	location := &w.transfer.location
	ui.MenuButton(c, "文件操作", func(menu *ui.Menu) {
		if item.Remote.ID != "" && menu.Item("打开云端所在目录").Disabled(location.running).Chosen() {
			w.locateUploadCloud(target)
		}
		label := "在资源管理器中显示源文件"
		if runtime.GOOS == "darwin" {
			label = "在访达中显示源文件"
		}
		if menu.Item(label).Disabled(location.running).Chosen() {
			w.locateUploadSource(target)
		}
	}).Label(item.RelativePath + " 的文件操作")
	if location.target == target {
		if location.running {
			ui.Text(c, "正在查找文件").TextColor(c.Theme().TextMuted)
		} else if location.problem != "" {
			ui.Text(c, location.problem).TextColor(c.Theme().Danger)
		}
	}
}

func (w *Workspace) locateUploadCloud(target uploadSourceTarget) {
	page := w.preferences.Page
	w.transfer.location = uploadLocationView{target: target, running: true}
	go func() {
		result, err := w.jobs.LocateUploadCloud(w.ctx, target.jobID, target.relativePath)
		w.window.Update(func() {
			location := &w.transfer.location
			location.running = false
			if w.quitting || w.preferences.Page != page || !w.transfer.selection.Has(target.jobID) {
				return
			}
			if err != nil {
				if !errors.Is(err, context.Canceled) {
					location.problem = err.Error()
				}
				return
			}
			f := w.files[result.Provider()]
			if !result.Apply(w.accounts, f.directory) {
				location.problem = "网盘账号已变化，请重新定位。"
				return
			}
			f.problem, f.query = "", ""
			f.resetTree()
			f.syncSelection()
			f.cloudFocus = result.Focus()
			w.preferences.Page, w.preferences.RecentProvider = string(result.Provider()), string(result.Provider())
			w.allProviders = false
		})
	}()
}

func (w *Workspace) locateUploadSource(target uploadSourceTarget) {
	w.transfer.location = uploadLocationView{target: target, running: true}
	go func() {
		err := w.jobs.RevealUploadSource(target.jobID, target.relativePath)
		w.window.Update(func() {
			location := &w.transfer.location
			location.running = false
			if err != nil && !w.quitting {
				location.problem = err.Error()
			}
		})
	}()
}
