package ui

import (
	"fmt"
	"strings"

	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
)

type directoryEdit struct {
	selection app.DirectorySelection
	text      string
	problem   string
	fresh     bool
}

type directoryDelete struct {
	view      *directoryView
	selection app.DirectorySelection
}

func (w *Workspace) directoryActions(c *ui.Context, f *directoryView, width float32) {
	d := f.directory
	_, targetReady := d.Target(d.Root())
	canUpload := w.jobs != nil && targetReady && !f.busy
	canTrash := targetReady && !f.busy && len(d.Selection()) > 0
	canRefresh := !f.busy && !d.Loading(d.Root())
	if width >= 520 && w.jobs != nil && ui.Button(c, "上传").Disabled(!canUpload).Clicked() {
		w.chooseUpload(f, d.Root())
	}
	if width < 700 {
		ui.MenuButton(c, "操作", func(m *ui.Menu) {
			if width < 520 && w.jobs != nil && m.Item("上传").Disabled(!canUpload).Chosen() {
				w.chooseUpload(f, d.Root())
			}
			if m.Item("移到回收站").Disabled(!canTrash).Chosen() {
				w.prepareDirectoryDelete(f, d.Selection())
			}
			if m.Item("刷新").Disabled(!canRefresh).Chosen() {
				w.refreshDirectory(f)
			}
		}).Label("文件操作")
		return
	}
	if ui.Button(c, "移到回收站").Disabled(!canTrash).Clicked() {
		w.prepareDirectoryDelete(f, d.Selection())
	}
	if ui.Button(c, "刷新").Disabled(!canRefresh).Clicked() {
		w.refreshDirectory(f)
	}
}

func (w *Workspace) refreshDirectory(f *directoryView) {
	f.problem = ""
	w.fetchDirectory(f, f.directory.Refresh())
}

func (w *Workspace) directoryBackgroundMenu(f *directoryView, menu *ui.Menu) {
	d := f.directory
	target, ok := d.Target(d.Root())
	if menu.Item("新建文件夹").Disabled(!ok || f.busy).Chosen() {
		w.createDirectory(f, target, d.DefaultFolderName())
	}
}

func (w *Workspace) directoryRowMenu(f *directoryView, menu *ui.Menu, row int) {
	item := f.outline.Item(row)
	if item.status {
		return
	}
	d := f.directory
	_, available := d.Target(d.Root())
	if entry, ok := d.Entry(item.ref); ok && entry.IsDirectory && w.jobs != nil &&
		menu.Item("上传到此文件夹").Disabled(!available || f.busy).Chosen() {
		w.chooseUpload(f, item.ref)
	}
	if menu.Item("重命名").Disabled(!available || f.busy).Chosen() {
		w.beginDirectoryEdit(f, item.ref)
	}
	if menu.Item("移到回收站").Disabled(!available || f.busy).Chosen() {
		refs := d.Selection()
		if !f.selection.Has(item) || len(refs) == 0 {
			refs = []app.RemoteRef{item.ref}
		}
		w.prepareDirectoryDelete(f, refs)
	}
}

func (w *Workspace) createDirectory(f *directoryView, target app.DirectoryTarget, name string) {
	f.busy, f.problem = true, ""
	f.edit = nil
	go func() {
		entry, err := target.Create(w.ctx, w.accounts, name)
		w.window.Update(func() {
			f.busy = false
			if err != nil {
				f.problem = err.Error()
				return
			}
			if f.directory.ApplyCreated(target, entry) {
				f.query = ""
				f.syncSelection()
				w.beginDirectoryEdit(f, entry.Ref)
			}
		})
	}()
}

func (w *Workspace) beginDirectoryEdit(f *directoryView, ref app.RemoteRef) {
	selection, ok := f.directory.FreezeSelection([]app.RemoteRef{ref})
	if !ok {
		return
	}
	f.edit = &directoryEdit{selection: selection, text: selection.Items[0].Entry.Name, fresh: true}
	f.problem = ""
	w.window.Invalidate()
}

func (w *Workspace) directoryNameCell(c *ui.Context, f *directoryView, entry app.RemoteEntry) {
	edit := f.edit
	if edit == nil || edit.selection.Items[0].Entry.Ref != entry.Ref {
		ui.Text(c, entry.Name).SingleLine().Tooltip(entry.Name).Grow(1)
		return
	}
	ui.Column(c).Grow(1).MinWidth(0).Children(func() {
		input := ui.TextInput(c, &edit.text).Label("名称").Disabled(f.busy).FillWidth()
		if edit.fresh {
			input.Focus().SetTextSelection(0, len([]rune(edit.text)))
			edit.fresh = false
		}
		if input.Changed() {
			edit.problem = ""
		}
		if !f.busy {
			switch {
			case input.Shortcut(0, ui.KeyEscape):
				f.edit = nil
				w.window.Invalidate()
			case input.Submitted(), input.FocusLeft():
				w.renameDirectoryEntry(f, edit)
			}
		}
		if edit.problem != "" {
			ui.Text(c, edit.problem).TextColor(c.Theme().Danger).Background(c.Theme().Background).Padding(2, 4).Radius(3).SingleLine().Tooltip(edit.problem)
		}
	})
}

func (w *Workspace) renameDirectoryEntry(f *directoryView, edit *directoryEdit) {
	name := strings.TrimSpace(edit.text)
	if name == edit.selection.Items[0].Entry.Name {
		f.edit = nil
		w.window.Invalidate()
		return
	}
	if err := app.ValidateRemoteName(name); err != nil {
		edit.problem = err.Error()
		w.window.Invalidate()
		return
	}
	f.busy = true
	go func() {
		entry, err := edit.selection.Rename(w.ctx, w.accounts, name)
		w.window.Update(func() {
			f.busy = false
			if err != nil {
				edit.problem = err.Error()
				return
			}
			f.directory.ApplyRenamed(edit.selection, entry)
			f.syncSelection()
			if f.edit == edit {
				f.edit = nil
			}
		})
	}()
}

func (w *Workspace) prepareDirectoryDelete(f *directoryView, refs []app.RemoteRef) {
	selection, ok := f.directory.FreezeSelection(refs)
	if !ok {
		return
	}
	w.directoryDelete = &directoryDelete{view: f, selection: selection}
	w.confirmDirectoryDelete = true
}

func (w *Workspace) directoryDeleteDialog(c *ui.Context) {
	pending := w.directoryDelete
	if pending == nil {
		return
	}
	names := make([]string, 0, len(pending.selection.Items))
	for _, item := range pending.selection.Items {
		names = append(names, item.Entry.Name)
	}
	title := fmt.Sprintf("将 %d 项移到网盘回收站？", len(names))
	result := ui.AlertDialog(c, &w.confirmDirectoryDelete, title, strings.Join(names, "\n"), "取消", "移到回收站")
	if !w.confirmDirectoryDelete {
		w.directoryDelete = nil
	}
	if result != 1 {
		return
	}
	f := pending.view
	f.busy, f.problem = true, ""
	go func() {
		result := pending.selection.Trash(w.ctx, w.accounts)
		w.window.Update(func() {
			f.busy = false
			f.directory.ApplyTrash(pending.selection, result)
			f.syncSelection()
			if len(result.Failures) != 0 {
				problems := make([]string, 0, len(result.Failures))
				for _, failure := range result.Failures {
					problems = append(problems, failure.Entry.Name+"："+failure.Err.Error())
				}
				f.problem = strings.Join(problems, "\n")
			}
		})
	}()
}
