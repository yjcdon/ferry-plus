// Package ui implements Ferry Drive's native desktop workspace.
package ui

import (
	"strings"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

const (
	baidu = "baidu"
	quark = "quark"
	all   = "transfers.all"
)

var providers = []struct{ id, title string }{
	{baidu, "百度网盘"},
	{quark, "夸克网盘"},
}

var transferPages = []struct{ id, title, empty string }{
	{all, "全部", "添加传输任务"},
	{"transfers.active", "进行中", "等待任务开始"},
	{"transfers.completed", "已完成", "完成的任务将显示在这里"},
	{"transfers.failed", "失败", "失败的任务将显示在这里"},
}

// Preferences contains the navigation and layout values restored at startup.
type Preferences struct {
	Page           string  `json:"page"`
	RecentProvider string  `json:"recentProvider"`
	SidebarWidth   float32 `json:"sidebarWidth"`
	SidebarHidden  bool    `json:"sidebarHidden"`
	DetailsWidth   float32 `json:"detailsWidth"`
	DetailsOpen    bool    `json:"detailsOpen"`
}

// Workspace owns the main window's navigation and local view state.
type Workspace struct {
	preferences    Preferences
	allProviders   bool
	lastTransfer   string
	transferSearch string
	focusSearch    bool
}

// NewWorkspace restores known pages and supplies the initial split sizes.
func NewWorkspace(p Preferences) *Workspace {
	if providerTitle(p.RecentProvider) == "" {
		p.RecentProvider = baidu
	}
	if providerTitle(p.Page) == "" && transferIndex(p.Page) < 0 {
		p.Page = p.RecentProvider
	}
	if p.SidebarWidth == 0 {
		p.SidebarWidth = 200
	}
	if p.DetailsWidth == 0 {
		p.DetailsWidth = 320
	}
	p.SidebarWidth = min(max(p.SidebarWidth, 180), 300)
	p.DetailsWidth = max(p.DetailsWidth, 280)
	w := &Workspace{preferences: p, lastTransfer: all}
	if transferIndex(p.Page) >= 0 {
		w.allProviders = true
		w.lastTransfer = p.Page
	}
	return w
}

// Preferences returns the state to save when the workspace closes.
func (w *Workspace) Preferences() Preferences { return w.preferences }

// Menu connects the native menu and platform shortcuts to workspace commands.
func (w *Workspace) Menu(window *mygo.Window) *mygo.Menu {
	command := func(label, accelerator string, act func()) *mygo.MenuItem {
		return &mygo.MenuItem{Label: label, Accelerator: accelerator, Click: func(*mygo.MenuItem, *mygo.Window) {
			window.Update(act)
		}}
	}
	return mygo.NewMenu([]*mygo.MenuItem{
		{Role: mygo.RoleAppMenu},
		{Role: mygo.RoleEditMenu},
		{Label: "显示", Submenu: []*mygo.MenuItem{
			command("搜索任务", "CmdOrCtrl+F", func() {
				if transferIndex(w.preferences.Page) >= 0 {
					w.focusSearch = true
				}
			}),
			command("切换侧边栏", "", w.toggleSidebar),
			command("切换详情", "CmdOrCtrl+Alt+I", func() {
				width, _ := window.ContentSize()
				w.toggleDetails(float32(width))
			}),
		}},
		{Role: mygo.RoleWindowMenu},
	})
}

// View draws the workspace with solid surfaces and native input controls.
func (w *Workspace) View(c *ui.Context) {
	width, _ := c.Size()
	ui.Column(c).Fill().Background(c.Theme().Background).Children(func() {
		if w.preferences.SidebarHidden {
			w.content(c, width)
			return
		}
		split := ui.Split(c, &w.preferences.SidebarWidth, func() { w.sidebar(c) }, func() {
			w.content(c, width-w.preferences.SidebarWidth-1)
		}).Fill().SplitReset(200)
		if split.Changed() {
			w.preferences.SidebarWidth = min(max(w.preferences.SidebarWidth, 180), 300)
		}
	})
}

func (w *Workspace) sidebar(c *ui.Context) {
	ui.Column(c).Fill().Padding(max(8, c.TitleBar().Height+4), 8, 8).Children(func() {
		previous := w.preferences.Page
		ui.Sidebar(c, &w.preferences.Page, func() {
			ui.SidebarSection(c, "网盘", nil, func() {
				for _, provider := range providers {
					item := ui.SidebarItem(c, provider.id, nil, provider.title)
					if transferIndex(previous) >= 0 && !w.allProviders && w.preferences.RecentProvider == provider.id {
						item.Description("当前传输范围").Background(c.Theme().SurfaceHover)
					}
				}
			})
			ui.SidebarSection(c, "传输", nil, func() {
				for _, page := range transferPages {
					ui.SidebarItem(c, page.id, nil, page.title)
				}
				if !w.allProviders && ui.Button(c, "查看全部").Tooltip("查看全部网盘的传输").Clicked() {
					w.allProviders = true
					if transferIndex(w.preferences.Page) < 0 {
						w.preferences.Page = w.lastTransfer
					}
				}
			})
		}).Grow(1).Background(c.Theme().Background)
		if previous != w.preferences.Page {
			if providerTitle(w.preferences.Page) != "" {
				w.preferences.RecentProvider = w.preferences.Page
				w.allProviders = false
			} else {
				w.lastTransfer = w.preferences.Page
			}
		}
	})
}

func (w *Workspace) content(c *ui.Context, width float32) {
	index := transferIndex(w.preferences.Page)
	title := providerTitle(w.preferences.Page)
	if index >= 0 {
		title = transferPages[index].title
		if !w.allProviders {
			title = providerTitle(w.preferences.RecentProvider) + " · " + transferPages[index].title
		}
	}
	ui.Column(c).Fill().Children(func() {
		titlePadding := float32(8)
		if w.preferences.SidebarHidden {
			titlePadding = max(titlePadding, c.TitleBar().Left+8)
		}
		ui.Toolbar(c, func() {
			sidebar := "隐藏侧边栏"
			if w.preferences.SidebarHidden {
				sidebar = "显示侧边栏"
			}
			if ui.Button(c, sidebar).Clicked() {
				w.toggleSidebar()
			}
			ui.Text(c, title).Bold().SingleLine()
			ui.Spacer(c)
			if index >= 0 {
				search := ui.TextInput(c, &w.transferSearch).Label("搜索任务").Placeholder("搜索任务").Width(160)
				if w.focusSearch {
					search.Focus()
					w.focusSearch = false
				}
				if ui.Button(c, "详情").Label("切换详情").Disabled(width < 640 && !w.preferences.DetailsOpen && w.preferences.SidebarHidden).Clicked() {
					windowWidth, _ := c.Size()
					w.toggleDetails(windowWidth)
				}
			}
		}).Height(48).Padding(0, 8, 0, titlePadding).DragWindow()
		if index < 0 {
			w.fileLanding(c, title)
			return
		}
		if w.preferences.DetailsOpen && width >= 640 {
			details := min(w.preferences.DetailsWidth, width/2, width-329)
			listWidth := width - details - 1
			split := ui.Split(c, &listWidth, func() { w.transferLanding(c, index) }, func() {
				ui.Column(c).Fill().Center().Children(func() {
					ui.Text(c, "选择任务查看详情").TextColor(c.Theme().TextMuted)
				})
			}).Grow(1)
			if split.Changed() {
				w.preferences.DetailsWidth = min(max(width-listWidth-1, 280), width/2, width-329)
			}
		} else {
			w.transferLanding(c, index)
		}
	})
}

func (w *Workspace) fileLanding(c *ui.Context, title string) {
	ui.Toolbar(c, func() {
		ui.Button(c, "返回").Disabled(true)
		ui.Text(c, "根目录")
	})
	ui.Column(c).Grow(1).FillWidth().Center().Gap(8).Children(func() {
		ui.Text(c, "登录"+title).Bold()
		ui.Button(c, "登录").Disabled(true)
	})
}

func (w *Workspace) transferLanding(c *ui.Context, index int) {
	title := transferPages[index].empty
	if strings.TrimSpace(w.transferSearch) != "" {
		title = "试试其他关键词"
	}
	ui.Column(c).Grow(1).FillWidth().Center().Children(func() {
		ui.Text(c, title).TextColor(c.Theme().TextMuted)
	})
}

func (w *Workspace) toggleSidebar() {
	w.preferences.SidebarHidden = !w.preferences.SidebarHidden
}

func (w *Workspace) toggleDetails(windowWidth float32) {
	if transferIndex(w.preferences.Page) < 0 {
		return
	}
	w.preferences.DetailsOpen = !w.preferences.DetailsOpen
	if w.preferences.DetailsOpen && windowWidth-w.preferences.SidebarWidth-1 < 640 {
		w.preferences.SidebarHidden = true
	}
}

func providerTitle(id string) string {
	for _, provider := range providers {
		if provider.id == id {
			return provider.title
		}
	}
	return ""
}

func transferIndex(id string) int {
	for i, page := range transferPages {
		if page.id == id {
			return i
		}
	}
	return -1
}
