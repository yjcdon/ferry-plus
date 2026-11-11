package ui

import (
	"fmt"
	"strings"

	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
)

type directoryRow struct {
	ref    app.RemoteRef
	status bool
}

type directoryView struct {
	directory      *app.Directory
	outline        ui.OutlineState[directoryRow]
	selection      ui.Selection[directoryRow]
	focus          int
	cloudFocus     app.RemoteRef
	sort           ui.SortOrder
	query          string
	busy           bool
	problem        string
	edit           *directoryEdit
	refreshPending bool
}

var fileColumns = []ui.TableColumn{
	{ID: "name", Title: "名称", Width: 320, MinWidth: 180, Sortable: true},
	{ID: "modified", Title: "修改日期", Width: 200, MinWidth: 100, Sortable: true},
	{ID: "size", Title: "大小", Width: 90, MinWidth: 60, Sortable: true, Align: ui.End},
}

func newDirectoryView(provider app.Provider, location app.DirectoryLocation) *directoryView {
	directory := app.NewDirectory(provider)
	directory.RestoreLocation(location)
	f := &directoryView{directory: directory, sort: ui.SortOrder{Column: "name"}}
	f.resetTree()
	return f
}

func (f *directoryView) resetTree() {
	f.focus = -1
	f.cloudFocus = app.RemoteRef{}
	f.edit = nil
	f.refreshPending = false
	f.selection.Clear()
	f.outline = ui.OutlineState[directoryRow]{Indent: 18}
	f.outline.List.Selected = &f.focus
	f.outline.List.Selection = &f.selection
	f.outline.List.Sort = &f.sort
	f.outline.List.KeepOffset = true
	f.outline.List.Label = func(i int) string {
		if row := f.outline.Item(i); !row.status {
			if entry, ok := f.directory.Entry(row.ref); ok {
				return entry.Name
			}
		}
		return ""
	}
}

// AccountChanged schedules directory state synchronization on the UI thread.
func (w *Workspace) AccountChanged(provider app.Provider) {
	if w.jobs != nil {
		go w.jobs.AccountsChanged()
	}
	w.window.Update(func() {
		if w.settingsWindow != nil {
			w.settingsWindow.Invalidate()
		}
		f := w.files[provider]
		session := w.accounts.Session(provider)
		previous := f.directory.Location().AccountID
		if f.directory.SetSession(session) {
			f.resetTree()
			if previous != session.ID {
				f.query = ""
			}
		}
		if w.preferences.Page == string(provider) {
			w.ensureDirectory(f)
		}
	})
}

func (w *Workspace) ensureDirectory(f *directoryView) {
	d := f.directory
	if !d.Loaded(d.Root()) && !d.Loading(d.Root()) && d.LoadError(d.Root()) == nil {
		w.fetchDirectory(f, d.Refresh())
	}
}

// refreshUploadDirectory starts a pending refresh as soon as the visible
// directory is ready. A hidden page keeps the flag until it is opened.
func (w *Workspace) refreshUploadDirectory(f *directoryView) {
	d := f.directory
	if !f.refreshPending || f.busy || f.edit != nil || d.Loading(d.Root()) ||
		w.preferences.Page != string(d.Provider()) {
		return
	}
	f.refreshPending = false
	w.fetchDirectory(f, d.Refresh())
}

func (w *Workspace) fetchDirectory(f *directoryView, request *app.DirectoryRequest) {
	if request == nil {
		return
	}
	go func() {
		result := request.Fetch(w.ctx)
		request.ReportExpiredSession(w.accounts, result)
		w.window.Update(func() {
			if f.directory.Apply(request, result) {
				f.syncSelection()
				w.refreshUploadDirectory(f)
			}
		})
	}()
}

func (w *Workspace) navigateDirectory(f *directoryView, changed bool) {
	if !changed {
		return
	}
	f.query = ""
	f.problem = ""
	f.resetTree()
	w.fetchDirectory(f, f.directory.Refresh())
	w.window.Invalidate()
}

func (w *Workspace) directoryToolbar(c *ui.Context, f *directoryView, width float32) {
	d := f.directory
	trail := d.Trail()
	ui.Toolbar(c, func() {
		if workspaceToolbarButton(c, "返回", backIcon).Disabled(!d.CanGoUp()).Clicked() {
			w.navigateDirectory(f, d.Up())
		}
		if len(trail) == 0 {
			ui.Text(c, "根目录")
		} else {
			if ui.Button(c, "根目录").Clicked() {
				w.navigateDirectory(f, d.Navigate(-1))
			}
			start := 0
			if len(trail) > 2 && width < 700 {
				start = len(trail) - 1
				ui.MenuButton(c, "上级目录", func(m *ui.Menu) {
					for i, entry := range trail[:start] {
						if m.Item(entry.Name).Chosen() {
							w.navigateDirectory(f, d.Navigate(i))
						}
					}
				})
			}
			for i, entry := range trail[start:] {
				ui.Text(c, "›").TextColor(c.Theme().TextMuted)
				if i+start == len(trail)-1 {
					ui.Text(c, entry.Name).SingleLine().Tooltip(entry.Name)
				} else if ui.Button(c, entry.Name).MaxWidth(160).Tooltip(entry.Name).Clicked() {
					w.navigateDirectory(f, d.Navigate(i+start))
				}
			}
		}
	})
}

func (w *Workspace) directorySearch(c *ui.Context, f *directoryView, width float32) {
	searchWidth := float32(202)
	if width < 500 {
		searchWidth = 152
	}
	theme := c.Theme()
	search := ui.SearchField(c, &f.query).Label("搜索当前目录").Placeholder("搜索当前目录").
		Size(searchWidth, 32).Radius(16).Padding(0, 12).Margin(0, 0, 0, 8).
		Background(theme.Background).Border(1, theme.Border)
	if w.focusSearch {
		search.Focus()
		w.focusSearch = false
	}
	if search.Changed() {
		f.directory.SetQuery(f.query)
		f.syncSelection()
	}
}

func (w *Workspace) directoryBody(c *ui.Context, f *directoryView) {
	d := f.directory
	root := d.Root()
	if !d.Loaded(root) {
		if err := d.LoadError(root); err != nil {
			ui.Column(c).Grow(1).FillWidth().Center().Gap(8).Padding(16).Children(func() {
				workspaceEmptyLabel(c, "网盘读取失败", warningIcon)
				ui.Text(c, err.Error()).TextColor(c.Theme().TextMuted)
				ui.Row(c).Gap(8).Children(func() {
					if ui.Button(c, "重试").Clicked() {
						w.fetchDirectory(f, d.Refresh())
					}
					if ui.Button(c, "重新登录").Clicked() {
						w.showLogin(d.Provider())
					}
				})
			})
		} else {
			w.directoryEmpty(c, "加载中", nil)
		}
		return
	}
	if err := d.LoadError(root); err != nil {
		ui.Text(c, "更新失败："+err.Error()).Padding(8, 12).TextColor(c.Theme().Danger)
	}
	if f.problem != "" {
		ui.Text(c, f.problem).Padding(8, 12).TextColor(c.Theme().Danger)
	}
	roots := d.Roots()
	switch {
	case len(roots) == 0 && strings.TrimSpace(f.query) != "":
		empty := w.directoryEmpty(c, "试试其他关键词", searchIcon).ContextMenu(func(m *ui.Menu) { w.directoryBackgroundMenu(f, m) })
		w.directoryDrop(empty, f, root)
	case len(roots) == 0:
		empty := w.directoryEmpty(c, "此目录为空", folderIcon).ContextMenu(func(m *ui.Menu) { w.directoryBackgroundMenu(f, m) })
		w.directoryDrop(empty, f, root)
	default:
		w.directoryTable(c, f, roots)
	}
	if items := d.SelectedEntries(); len(items) > 0 || d.Loading(root) {
		workspaceStatusBar(c, func() {
			if d.Loading(root) {
				ui.Text(c, "正在刷新").TextColor(c.Theme().TextMuted)
			}
			if len(items) > 0 {
				ui.Textf(c, "已选择 %d 项", len(items))
			}
		})
	}
}

func (w *Workspace) directoryEmpty(c *ui.Context, title string, icon *ui.SVG) ui.Element {
	return ui.Column(c).Grow(1).FillWidth().Center().Gap(8).Children(func() {
		if icon != nil {
			workspaceEmptyLabel(c, title, icon)
		} else {
			ui.Spinner(c).Label(title)
			ui.Text(c, title).TextColor(c.Theme().TextMuted).AccessHidden(true)
		}
	})
}

func (w *Workspace) directoryTable(c *ui.Context, f *directoryView, entries []app.RemoteEntry) {
	d := f.directory
	f.outline.List.Columns.Widths = w.preferences.ColumnWidths
	f.outline.List.CellMenu = func(menu *ui.Menu, row, _ int) { w.directoryRowMenu(f, menu, row) }
	beforeSort := f.sort
	beforeOpen := captureExpanded(f)
	rows := makeDirectoryRows(entries)
	var dropRows []directoryDropRow
	table := ui.OutlineTable(c, &f.outline, fileColumns, rows, f.children, func(row directoryRow, column int) {
		if row.status {
			if column == 0 {
				f.branchStatus(c, row.ref, func() { w.fetchDirectory(f, d.Expand(row.ref)) })
			}
			return
		}
		entry, ok := d.Entry(row.ref)
		if !ok {
			return
		}
		switch column {
		case 0:
			content := ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
				f.selectionCheckbox(c, row, entry.Name)
				w.directoryNameCell(c, f, entry)
			})
			if entry.IsDirectory {
				dropRows = append(dropRows, directoryDropRow{row.ref, directoryDropRowBounds(c, content)})
			}
		case 1:
			text := "—"
			if entry.ModifiedAt != nil {
				text = entry.ModifiedAt.Local().Format("2006-01-02 15:04")
			}
			ui.Text(c, text).SingleLine()
		case 2:
			text := "—"
			if !entry.IsDirectory {
				text = fileSize(entry.Size)
			}
			ui.Text(c, text).SingleLine().TextAlign(ui.End)
		}
	}).Grow(1).MinHeight(0).Dividers(1, c.Theme().Border).
		ContextMenu(func(m *ui.Menu) { w.directoryBackgroundMenu(f, m) })
	w.directoryDrop(table, f, directoryTableDropTarget(c, table, dropRows, d.Root()))

	w.preferences.ColumnWidths = f.outline.List.Columns.Widths
	if f.sort != beforeSort {
		sort := app.SortName
		switch f.sort.Column {
		case "modified":
			sort = app.SortModified
		case "size":
			sort = app.SortSize
		}
		d.SetSort(sort, f.sort.Descending)
		w.window.Invalidate()
	}
	if strings.TrimSpace(f.query) == "" {
		f.applyExpansion(beforeOpen, func(ref app.RemoteRef) { w.fetchDirectory(f, d.Expand(ref)) })
	}
	if table.Changed() {
		f.applySelection()
	}
	if f.cloudFocus.ID != "" {
		for i := range f.outline.Rows() {
			if row := f.outline.Item(i); !row.status && row.ref == f.cloudFocus {
				f.focus = i
				f.outline.List.ScrollIntoView(i)
				break
			}
		}
		f.cloudFocus = app.RemoteRef{}
	}
	if edit := f.edit; edit != nil && edit.fresh {
		for i := range f.outline.Rows() {
			if row := f.outline.Item(i); row.ref == edit.selection.Items[0].Entry.Ref && !row.status {
				f.outline.List.ScrollIntoView(i)
				break
			}
		}
	}
	if f.edit != nil {
		return
	}
	if f.outline.List.Shortcut(c, ui.Cmd, ui.KeyUp) {
		w.navigateDirectory(f, d.Up())
		return
	}
	if f.focus >= 0 && f.focus < f.outline.Rows() {
		row := f.outline.Item(f.focus)
		if !row.status && !f.busy && f.outline.List.Shortcut(c, 0, ui.KeyF2) {
			w.beginDirectoryEdit(f, row.ref)
		}
		if table.Submitted() || f.outline.List.Shortcut(c, ui.Cmd, ui.KeyDown) {
			w.navigateDirectory(f, d.Enter(row.ref))
			return
		}
		if f.outline.List.Shortcut(c, 0, ui.KeySpace) {
			if f.selection.Has(row) {
				f.selection.Remove(row)
			} else if !row.status {
				f.selection.Add(row)
			}
			f.applySelection()
		}
	}
}

func captureExpanded(f *directoryView) map[directoryRow]bool {
	open := make(map[directoryRow]bool, f.outline.Open.Len())
	for row := range f.outline.Open.All() {
		open[row] = true
	}
	return open
}

func (f *directoryView) applyExpansion(before map[directoryRow]bool, expand func(app.RemoteRef)) {
	for row := range f.outline.Open.All() {
		if !before[row] {
			expand(row.ref)
		}
	}
	for row := range before {
		if !f.outline.Open.Has(row) {
			f.directory.Collapse(row.ref)
			f.syncSelection()
		}
	}
}

func (f *directoryView) selectionCheckbox(c *ui.Context, row directoryRow, name string) {
	checked := f.selection.Has(row)
	if ui.Checkbox(c, &checked, "").Label("选择 " + name).Changed() {
		if checked {
			f.selection.Add(row)
		} else {
			f.selection.Remove(row)
		}
		f.applySelection()
	}
}

func makeDirectoryRows(entries []app.RemoteEntry) []directoryRow {
	rows := make([]directoryRow, len(entries))
	for i, entry := range entries {
		rows[i] = directoryRow{ref: entry.Ref}
	}
	return rows
}

func (f *directoryView) children(row directoryRow) []directoryRow {
	if row.status || strings.TrimSpace(f.query) != "" {
		return nil
	}
	if entry, ok := f.directory.Entry(row.ref); !ok || !entry.IsDirectory {
		return nil
	}
	children := f.directory.Children(row.ref)
	if len(children) > 0 {
		return makeDirectoryRows(children)
	}
	return []directoryRow{{ref: row.ref, status: true}}
}

func (f *directoryView) branchStatus(c *ui.Context, ref app.RemoteRef, retry func()) {
	if err := f.directory.LoadError(ref); err != nil {
		ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
			ui.Text(c, err.Error()).TextColor(c.Theme().Danger).SingleLine().Grow(1)
			if ui.Button(c, "重试").Clicked() {
				retry()
			}
		})
		return
	}
	text := "正在读取目录"
	if f.directory.Loaded(ref) {
		text = "此目录为空"
	}
	ui.Text(c, text).TextColor(c.Theme().TextMuted)
}

func (f *directoryView) applySelection() {
	refs := make([]app.RemoteRef, 0, f.selection.Len())
	for row := range f.selection.All() {
		if !row.status {
			refs = append(refs, row.ref)
		}
	}
	f.directory.SetSelection(refs)
	f.syncSelection()
}

func (f *directoryView) syncSelection() {
	f.selection.Clear()
	for _, ref := range f.directory.Selection() {
		f.selection.Add(directoryRow{ref: ref})
	}
}

func fileSize(size int64) string {
	unit := "B"
	value := float64(size)
	for _, next := range []string{"KB", "MB", "GB", "TB"} {
		if value < 1000 {
			break
		}
		value /= 1000
		unit = next
	}
	if unit == "B" {
		return fmt.Sprintf("%d B", size)
	}
	return fmt.Sprintf("%.1f %s", value, unit)
}
