package ui

import (
	"path/filepath"

	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

type downloadPrompt struct {
	selection app.DirectorySelection
	folder    platform.LocalReference
	problem   string
	busy      bool
	focused   bool
}

func (w *Workspace) beginDownload(f *directoryView, refs []app.RemoteRef) {
	if w.jobs == nil || w.downloadOpen {
		return
	}
	selection, ready := f.directory.FreezeSelection(refs)
	if !ready {
		return
	}
	prompt := &downloadPrompt{selection: selection, busy: true}
	w.download, w.downloadOpen = prompt, true
	go func() {
		access, err := w.settings.OpenDownloadDirectory()
		var folder platform.LocalReference
		if err == nil {
			folder = access.Reference
			access.Close()
		}
		w.window.Update(func() {
			prompt.busy = false
			if err != nil {
				prompt.problem = err.Error()
			} else {
				prompt.folder = folder
			}
		})
	}()
}

func (w *Workspace) pickDownloadFolder(done func(platform.LocalReference, error)) {
	if w.chooser != nil {
		return
	}
	w.window.Update(func() {
		if w.chooser != nil {
			return
		}
		w.chooser = platform.ChooseDownloadFolder(w.window, func(folder platform.LocalReference, err error) {
			w.window.Update(func() {
				w.chooser = nil
				done(folder, err)
			})
		})
	})
}

func (w *Workspace) downloadDialog(c *ui.Context) {
	p := w.download
	if p == nil {
		return
	}
	width, _ := c.Size()
	ui.Modal(c, &w.downloadOpen, func() {
		ui.Column(c).Width(min(620, width-48)).Gap(12).Children(func() {
			ui.Text(c, "下载所选项目").FontSize(17).Bold()
			ui.Scroll(c).Height(156).FillWidth().Children(func() {
				for _, item := range p.selection.Items {
					ui.Text(c, item.Entry.Name).SingleLine().Tooltip(item.Entry.Name)
				}
			})
			if p.problem != "" {
				ui.Text(c, p.problem).TextColor(c.Theme().Danger)
			}
			ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
				w.downloadFolderButton(c, p.folder, p.busy, func(folder platform.LocalReference, err error) {
					if err != nil {
						p.problem = err.Error()
					} else if folder.Path != "" {
						p.folder, p.problem = folder, ""
					}
				})
				ui.Spacer(c)
				if ui.Button(c, "取消").Disabled(p.busy && p.folder.Path != "").Clicked() {
					w.downloadOpen = false
				}
				ready := !p.busy && p.folder.Path != ""
				button := ui.PrimaryButton(c, "下载").Disabled(!ready)
				if ready && !p.focused {
					button.Focus()
					p.focused = true
				}
				if button.Clicked() {
					w.submitDownload(p)
				}
			})
		})
	})
	if !w.downloadOpen {
		if p.busy && p.folder.Path != "" {
			w.downloadOpen = true
		} else {
			w.download = nil
		}
	}
}

func (w *Workspace) downloadFolderButton(c *ui.Context, folder platform.LocalReference, busy bool, done func(platform.LocalReference, error)) {
	ui.Text(c, "下载到")
	name := "选择目录"
	if folder.Path != "" {
		name = filepath.Base(folder.Path)
	}
	if ui.Button(c, name).Label("选择下载目录").Tooltip(folder.Path).Disabled(busy || w.chooser != nil).Clicked() {
		w.pickDownloadFolder(done)
	}
}

func (w *Workspace) submitDownload(p *downloadPrompt) {
	p.busy, p.problem = true, ""
	folder := p.folder
	go func() {
		_, err := w.jobs.EnqueueDownload(p.selection, folder)
		w.window.Update(func() {
			p.busy = false
			if err != nil {
				p.problem = "下载准备失败：" + err.Error()
			} else if w.download == p {
				w.downloadOpen = false
			}
		})
	}()
}
