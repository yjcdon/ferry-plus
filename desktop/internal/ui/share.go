package ui

import (
	"context"
	"errors"
	"strings"

	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
	"github.com/yjcdon/ferry-drive/desktop/internal/quark"
)

type sharePrompt struct {
	ctx    context.Context
	cancel context.CancelFunc

	text, code, problem        string
	pastedText, pastedCode     string
	opening, saving, focusCode bool
	browser                    *app.ShareBrowser
	files                      *directoryView
	selectedInitially          bool
	folder                     platform.LocalReference
	folderError                string
}

func (w *Workspace) showShare() {
	w.window.Update(func() {
		w.openSharePrompt(app.ShareLink{})
		p := w.share
		if p != nil && p.text == "" {
			w.readShareClipboard(func(link app.ShareLink, _ bool) {
				if w.share == p && p.text == "" && link.URL != "" {
					w.fillSharePrompt(p, link)
				}
			})
		}
	})
}

func (w *Workspace) openSharePrompt(link app.ShareLink) {
	if w.jobs == nil || w.quitting || w.shareOpen || w.downloadOpen || w.confirmDirectoryDelete || w.confirmLogout {
		return
	}
	p := &sharePrompt{}
	p.ctx, p.cancel = context.WithCancel(w.ctx)
	w.share, w.shareOpen = p, true
	go func() {
		access, err := w.settings.OpenDownloadDirectory()
		var folder platform.LocalReference
		if err == nil {
			folder = access.Reference
			access.Close()
		}
		w.window.Update(func() {
			if err != nil {
				p.folderError = err.Error()
			} else if p.folder.Path == "" && p.folderError == "" {
				p.folder = folder
			}
		})
	}()
	if link.URL != "" {
		w.fillSharePrompt(p, link)
	}
	w.window.Invalidate()
}

func (w *Workspace) fillSharePrompt(p *sharePrompt, link app.ShareLink) {
	p.text, p.code = link.URL, link.Passcode
	p.pastedText, p.pastedCode = p.text, p.code
	w.openShareLink(p)
}

func (w *Workspace) openShareLink(p *sharePrompt) {
	if p.opening || p.saving {
		return
	}
	link, err := app.ParseShareInput(p.text, p.code)
	if err != nil {
		p.problem = err.Error()
		return
	}
	p.releaseBrowser()
	p.opening, p.problem = true, ""
	go func() {
		browser, err := app.OpenShare(p.ctx, w.accounts, link)
		w.window.Update(func() {
			if p.ctx.Err() != nil {
				if browser != nil {
					browser.Close()
				}
				return
			}
			p.opening = false
			if err != nil {
				p.problem = err.Error()
				p.focusCode = errors.Is(err, baidu.ErrPasswordRequired) || errors.Is(err, baidu.ErrWrongPassword) ||
					errors.Is(err, quark.ErrShareRequiresCode) || errors.Is(err, quark.ErrInvalidPasscode)
				return
			}
			p.browser = browser
			p.files = &directoryView{directory: browser.Tree()}
			p.files.resetTree()
			w.fetchShare(p, browser.Refresh())
		})
	}()
}

func (p *sharePrompt) releaseBrowser() {
	if p.browser != nil {
		p.browser.Close()
		p.browser, p.files = nil, nil
	}
	p.selectedInitially = false
}

func (w *Workspace) fetchShare(p *sharePrompt, request *app.ShareRequest) {
	if request == nil {
		return
	}
	browser := p.browser
	go func() {
		page := request.Fetch(p.ctx)
		w.window.Update(func() {
			if p.ctx.Err() != nil || p.browser != browser || !browser.Apply(request, page) {
				return
			}
			tree := browser.Tree()
			if !p.selectedInitially && tree.Loaded(tree.Root()) {
				tree.SelectAll()
				p.selectedInitially = true
			}
			p.files.syncSelection()
		})
	}()
}

func (w *Workspace) shareDialog(c *ui.Context) {
	p := w.share
	if p == nil {
		return
	}
	width, height := c.Size()
	ui.Modal(c, &w.shareOpen, func() {
		ui.Column(c).Width(min(width-48, 640)).Height(min(height-48, 516)).Gap(10).Children(func() {
			w.shareFields(c, p)
			ui.Divider(c)
			w.shareContent(c, p)
			ui.Divider(c)
			w.shareFooter(c, p)
		})
	})
	if !w.shareOpen {
		if p.saving {
			w.shareOpen = true
		} else {
			p.cancel()
			p.releaseBrowser()
			w.share = nil
		}
	}
}

func (w *Workspace) shareFields(c *ui.Context, p *sharePrompt) {
	ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
		disabled := p.opening || p.saving
		link := ui.TextInput(c, &p.text).Label("分享链接").Placeholder("粘贴分享链接").
			Grow(1).MinWidth(80).AutoFocus().Disabled(disabled)
		ui.Text(c, "提取码")
		code := ui.TextInput(c, &p.code).Label("提取码").Placeholder("4 位").Width(64).Disabled(disabled)
		if p.focusCode {
			code.Focus()
			p.focusCode = false
		}
		if link.Changed() || code.Changed() {
			p.releaseBrowser()
			p.problem = ""
			if p.code == "" {
				if parsed, err := app.ParseShareInput(p.text, ""); err == nil {
					p.code = parsed.Passcode
				}
			}
		}
		submitted := link.Submitted() || code.Submitted()
		if ui.Button(c, "打开").Disabled(disabled || strings.TrimSpace(p.text) == "").Clicked() ||
			submitted && p.browser == nil {
			w.openShareLink(p)
		} else if submitted && p.browser != nil {
			w.submitShare(p)
		}
	})
	if p.pastedText != "" && p.pastedText == p.text {
		text := "已从剪贴板填入链接"
		if p.pastedCode != "" && p.pastedCode == p.code {
			text = "已从剪贴板填入链接和提取码"
		}
		ui.Text(c, text).TextColor(c.Theme().TextMuted)
	}
}

func (w *Workspace) shareContent(c *ui.Context, p *sharePrompt) {
	switch {
	case p.browser != nil:
		w.shareTree(c, p)
	case p.opening:
		w.directoryEmpty(c, "正在打开分享")
	case p.problem != "":
		ui.Column(c).Grow(1).FillWidth().Center().Gap(8).Children(func() {
			ui.Text(c, "分享打开失败").Bold()
			ui.Text(c, p.problem).TextColor(c.Theme().Danger)
			if link, err := app.ParseShareInput(p.text, p.code); err == nil {
				if w.accounts.Session(link.Provider).State != app.LoggedIn &&
					ui.Button(c, "登录"+providerTitle(string(link.Provider))).Clicked() {
					w.showLogin(link.Provider)
				}
				if ui.Button(c, "重试").Clicked() {
					w.openShareLink(p)
				}
			}
		})
	default:
		ui.Column(c).Grow(1).FillWidth().Center().Gap(6).Children(func() {
			ui.Text(c, "添加分享链接").Bold()
			ui.Text(c, "支持百度网盘和夸克网盘").TextColor(c.Theme().TextMuted)
		})
	}
}

func (w *Workspace) shareTree(c *ui.Context, p *sharePrompt) {
	f := p.files
	tree := p.browser.Tree()
	root := tree.Root()
	if !tree.Loaded(root) {
		if err := tree.LoadError(root); err != nil {
			ui.Column(c).Grow(1).FillWidth().Center().Gap(8).Children(func() {
				ui.Text(c, "分享读取失败").Bold()
				ui.Text(c, err.Error()).TextColor(c.Theme().Danger)
				if ui.Button(c, "重试").Clicked() {
					w.fetchShare(p, p.browser.Refresh())
				}
			})
		} else {
			w.directoryEmpty(c, "加载中")
		}
		return
	}
	roots := tree.Roots()
	all := ui.CheckOff
	if f.selection.Len() > 0 {
		all = ui.CheckOn
		for _, entry := range roots {
			if !f.selection.Has(directoryRow{ref: entry.Ref}) {
				all = ui.CheckMixed
				break
			}
		}
	}
	if ui.CheckboxState(c, &all, "全选").Disabled(len(roots) == 0).Changed() {
		if all == ui.CheckOn {
			tree.SelectAll()
		} else {
			tree.SetSelection(nil)
		}
		f.syncSelection()
	}
	if len(roots) == 0 {
		w.directoryEmpty(c, "分享目录为空")
		return
	}

	before := captureExpanded(f)
	list := ui.Outline(c, &f.outline, makeDirectoryRows(roots), f.children, func(row directoryRow) {
		if row.status {
			f.branchStatus(c, row.ref, func() { w.fetchShare(p, p.browser.Expand(row.ref)) })
			return
		}
		entry, ok := tree.Entry(row.ref)
		if !ok {
			return
		}
		ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
			f.selectionCheckbox(c, row, entry.Name)
			ui.Text(c, entry.Name).SingleLine().Tooltip(entry.Name).Grow(1)
			if !entry.IsDirectory {
				ui.Text(c, fileSize(entry.Size)).TextColor(c.Theme().TextMuted)
			}
		})
	}).Grow(1).MinHeight(0)
	f.applyExpansion(before, func(ref app.RemoteRef) { w.fetchShare(p, p.browser.Expand(ref)) })
	if list.Changed() {
		f.applySelection()
	}
}

func (w *Workspace) shareFooter(c *ui.Context, p *sharePrompt) {
	if p.browser != nil {
		if count := len(p.browser.Tree().Selection()); count > 0 {
			ui.Textf(c, "已选择 %d 项", count)
		}
	}
	if p.folderError != "" {
		ui.Text(c, p.folderError).TextColor(c.Theme().Danger)
	}
	if p.browser != nil && p.problem != "" {
		ui.Text(c, p.problem).TextColor(c.Theme().Danger)
	}
	ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
		w.downloadFolderButton(c, p.folder, p.saving, func(folder platform.LocalReference, err error) {
			if err != nil {
				p.folderError = err.Error()
			} else if folder.Path != "" {
				p.folder, p.folderError = folder, ""
			}
		})
		ui.Spacer(c)
		if ui.Button(c, "取消").Disabled(p.saving).Clicked() {
			w.shareOpen = false
		}
		enabled := p.browser != nil && len(p.browser.Tree().Selection()) > 0 && p.folder.Path != "" && !p.saving
		if ui.PrimaryButton(c, "下载").Disabled(!enabled).Clicked() {
			w.submitShare(p)
		}
	})
}

func (w *Workspace) submitShare(p *sharePrompt) {
	if p.saving || p.browser == nil || p.folder.Path == "" {
		return
	}
	selection, err := p.browser.Selection()
	if err != nil {
		p.problem = err.Error()
		return
	}
	disk := w.settings.Values().Disk(selection.Provider())
	p.saving, p.problem = true, ""
	folder := p.folder
	go func() {
		_, err := w.jobs.EnqueueShare(selection, folder, disk.TransferFolder, disk.CleanupAfterDownload)
		w.window.Update(func() {
			p.saving = false
			if err != nil {
				p.problem = "添加分享下载失败：" + err.Error()
			} else if w.share == p {
				w.shareOpen = false
			}
		})
	}()
}
