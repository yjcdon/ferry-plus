// Package ui implements Ferry Drive's native desktop workspace.
package ui

import (
	"context"
	_ "embed"
	"strings"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

const (
	baiduPage = string(app.Baidu)
	quarkPage = string(app.Quark)
	all       = "transfers.all"
)

//go:embed assets/BaiduNetdisk.png
var baiduLogo []byte

//go:embed assets/QuarkNetdisk.png
var quarkLogo []byte

var providers = []struct {
	id, title string
	logo      *ui.Bitmap
}{
	{baiduPage, "百度网盘", providerLogo(baiduLogo)},
	{quarkPage, "夸克网盘", providerLogo(quarkLogo)},
}

func providerLogo(data []byte) *ui.Bitmap {
	bitmap, err := ui.DecodeBitmap(data)
	if err != nil {
		panic(err)
	}
	return bitmap
}

var activeTransferIcon = workspaceIcon("M22 12a10 10 0 1 1-20 0 10 10 0 1 1 20 0z M8 16V8l-2 2 M8 8l2 2 M16 8v8l-2-2 M16 16l2-2")

var transferPages = []struct {
	id, title, empty string
	icon             *ui.SVG
}{
	{all, "全部", "添加传输任务", workspaceIcon("M3 14l3-8h12l3 8v5H3z M3 14h5l2 2h4l2-2h5 M8 10h8")},
	{"transfers.active", "进行中", "等待任务开始", activeTransferIcon},
	{"transfers.completed", "已完成", "完成的任务将显示在这里", workspaceIcon("M22 12a10 10 0 1 1-20 0 10 10 0 1 1 20 0z M7 12l3 3 7-7")},
	{"transfers.failed", "失败", "失败的任务将显示在这里", warningIcon},
}

var (
	sidebarIcon = workspaceIcon("M3 5h18v14H3z M9 5v14 M5 8h2 M5 11h2")
	detailsIcon = workspaceIcon("M3 5h18v14H3z M15 5v14 M17 8h2 M17 11h2")
	pauseIcon   = workspaceIcon("M9 5v14 M15 5v14")
	resumeIcon  = workspaceIcon("M8 5l11 7-11 7z")
	backIcon    = workspaceIcon("M14 6l-6 6 6 6")
	warningIcon = workspaceIcon("M12 3l10 17H2z M12 9v4 M12 16v.3")
	folderIcon  = workspaceIcon("M3 6h7l2 2h9v11H3z")
	searchIcon  = workspaceIcon("M16 10a6 6 0 1 1-12 0 6 6 0 1 1 12 0z M14.5 14.5l5 5")
	accountIcon = ui.MustParseSVG([]byte(`<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="1.7"/><circle cx="12" cy="9" r="3.5" fill="currentColor"/><path d="M5 19c1-3 3.5-4.5 7-4.5s6 1.5 7 4.5a10 10 0 0 1-14 0z" fill="currentColor"/></svg>`))
)

func workspaceIcon(path string) *ui.SVG {
	return ui.MustParseSVG([]byte(`<svg viewBox="0 0 24 24"><path fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" d="` + path + `"/></svg>`))
}

// Preferences contains the navigation and layout values restored at startup.
type Preferences struct {
	Page               string                                 `json:"page"`
	RecentProvider     string                                 `json:"recentProvider"`
	SidebarWidth       float32                                `json:"sidebarWidth"`
	SidebarHidden      bool                                   `json:"sidebarHidden"`
	DetailsWidth       float32                                `json:"detailsWidth"`
	DetailsOpen        bool                                   `json:"detailsOpen"`
	ColumnWidths       map[string]float32                     `json:"columnWidths,omitempty"`
	DirectoryLocations map[app.Provider]app.DirectoryLocation `json:"directoryLocations,omitempty"`
}

// Workspace owns the main window's navigation and local view state.
type Workspace struct {
	preferences            Preferences
	allProviders           bool
	lastTransfer           string
	transferSearch         string
	focusSearch            bool
	window                 *mygo.Window
	accounts               *app.Accounts
	loginWindows           map[app.Provider]*mygo.Window
	ctx                    context.Context
	logoutProvider         app.Provider
	confirmLogout          bool
	accountProblem         map[app.Provider]string
	files                  map[app.Provider]*directoryView
	directoryDelete        *directoryDelete
	confirmDirectoryDelete bool
	settings               *app.SettingsModel
	settingsReadError      error
	settingsChanged        func()
	settingsWindow         *mygo.Window
	aboutWindow            *mygo.Window
	jobs                   *app.Transfers
	transfer               transferView
	chooser                func()
	uploadDraft            []platform.LocalReference
	download               *downloadPrompt
	downloadOpen           bool
	share                  *sharePrompt
	shareOpen              bool
	quitting               bool
	quitReady              func()
	clipboardSequence      uint64
	clipboardLink          app.ShareLink
	notifiedStates         map[string]app.TransferState
}

// NewWorkspace restores known pages and supplies the initial split sizes.
func NewWorkspace(p Preferences) *Workspace {
	if providerTitle(p.RecentProvider) == "" {
		p.RecentProvider = baiduPage
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
func (w *Workspace) Preferences() Preferences {
	if w.preferences.DirectoryLocations == nil && len(w.files) != 0 {
		w.preferences.DirectoryLocations = make(map[app.Provider]app.DirectoryLocation)
	}
	for provider, f := range w.files {
		if location := f.directory.Location(); location.AccountID != "" {
			w.preferences.DirectoryLocations[provider] = location
		}
	}
	return w.preferences
}

// AttachAccounts enables login and account actions in the main window.
func (w *Workspace) AttachAccounts(ctx context.Context, window *mygo.Window, accounts *app.Accounts) {
	w.window, w.accounts, w.ctx = window, accounts, ctx
	w.loginWindows = make(map[app.Provider]*mygo.Window)
	w.accountProblem = make(map[app.Provider]string)
	w.files = make(map[app.Provider]*directoryView, len(providers))
	for _, entry := range providers {
		p := app.Provider(entry.id)
		w.files[p] = newDirectoryView(p, w.preferences.DirectoryLocations[p])
	}
}

// Menu connects the native menu and platform shortcuts to workspace commands.
func (w *Workspace) Menu(window *mygo.Window) *mygo.Menu {
	command := func(label, accelerator string, act func()) *mygo.MenuItem {
		return &mygo.MenuItem{Label: label, Accelerator: accelerator, Click: func(*mygo.MenuItem, *mygo.Window) {
			window.Update(act)
		}}
	}
	appMenu := &mygo.MenuItem{Label: "Ferry Drive", Submenu: []*mygo.MenuItem{
		command("关于 Ferry Drive", "", w.showAbout),
	}}
	if w.settings != nil {
		appMenu.Submenu = append(appMenu.Submenu, command("设置…", "CmdOrCtrl+,", w.showSettings))
	}
	appMenu.Submenu = append(appMenu.Submenu, mygo.Separator(), &mygo.MenuItem{Role: mygo.RoleQuit})
	fileMenu := &mygo.MenuItem{Label: "文件", Submenu: []*mygo.MenuItem{
		{Role: mygo.RoleClose},
	}}
	if w.jobs != nil {
		fileMenu.Submenu = append([]*mygo.MenuItem{
			command("添加链接", "CmdOrCtrl+N", w.showShare),
			command("上传", "CmdOrCtrl+U", w.uploadFromCurrent),
		}, fileMenu.Submenu...)
	}
	return mygo.NewMenu([]*mygo.MenuItem{
		appMenu,
		fileMenu,
		{Role: mygo.RoleEditMenu},
		{Label: "显示", Submenu: []*mygo.MenuItem{
			command("搜索", "CmdOrCtrl+F", func() { w.focusSearch = true }),
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
	jobs := w.filteredTransfers()
	root := ui.Column(c).Fill().Background(c.Theme().Background).Children(func() {
		if w.preferences.SidebarHidden {
			w.content(c, width, jobs)
			return
		}
		split := ui.Split(c, &w.preferences.SidebarWidth, func() { w.sidebar(c, jobs) }, func() {
			w.content(c, width-w.preferences.SidebarWidth-1, jobs)
		}).Fill().SplitReset(200)
		if split.Changed() {
			w.preferences.SidebarWidth = min(max(w.preferences.SidebarWidth, 180), 300)
		}
	})
	w.draftDrop(root)
	if w.confirmLogout && ui.AlertDialog(c, &w.confirmLogout,
		"退出"+providerTitle(string(w.logoutProvider))+"？",
		"退出后可以重新登录以继续使用该账号。", "取消", "退出登录") == 1 {
		w.logout(w.logoutProvider)
	}
	w.directoryDeleteDialog(c)
	w.downloadDialog(c)
	w.shareDialog(c)
	w.transferRemoveDialog(c)
	w.quitNotice(c)
}

func workspaceToolbarButton(c *ui.Context, label string, icon *ui.SVG) ui.Element {
	return ui.Button(c, "").Label(label).Tooltip(label).Children(func() {
		ui.Icon(c, icon).FontSize(18).AccessHidden(true)
	})
}

func (w *Workspace) sidebar(c *ui.Context, jobs []app.TransferJob) {
	top := float32(8)
	if c.TitleBar().Height > 0 {
		top = 44
	}
	ui.Column(c).Fill().Padding(top, 8, 8).Children(func() {
		previous := w.preferences.Page
		ui.Sidebar(c, &w.preferences.Page, func() {
			ui.SidebarSection(c, "网盘", nil, func() {
				for _, provider := range providers {
					item := ui.SidebarItem(c, provider.id, nil, provider.title).Reverse()
					item.Children(func() {
						ui.Image(c, provider.logo).Size(16, 16).Shrink(0).AccessHidden(true)
					})
					if transferIndex(previous) >= 0 && !w.allProviders && w.preferences.RecentProvider == provider.id {
						item.Description("当前传输范围").Background(c.Theme().SurfaceHover)
					}
				}
			})
			theme := c.Theme()
			ui.Column(c).Gap(theme.Space(0.5)).Shrink(0).Margin(theme.Space(3), 0, 0, 0).Children(func() {
				ui.Row(c).AlignItems(ui.Center).MinHeight(22).Padding(0, theme.Space(2)).Children(func() {
					ui.Text(c, "传输").FontSize(theme.FontSize - 1).FontWeight(600).TextColor(theme.TextMuted).
						Role(ui.RoleTreeItem).Level(1).Grow(1)
					if !w.allProviders {
						showAll := ui.ButtonBase(c).Role(ui.RoleButton).Label("查看全部").
							Tooltip("查看全部网盘的传输").Padding(4, 3).Radius(theme.Radius)
						if showAll.Hovered() {
							showAll.Background(theme.SurfaceHover)
						}
						showAll.Children(func() {
							ui.Text(c, "查看全部").FontSize(theme.FontSize - 1).TextColor(theme.Accent)
						})
						if showAll.Clicked() {
							w.allProviders = true
							if transferIndex(w.preferences.Page) < 0 {
								w.preferences.Page = w.lastTransfer
							}
						}
					}
				})
				for index, page := range transferPages {
					item := ui.SidebarItem(c, page.id, page.icon, page.title).Level(2)
					count := 0
					for _, job := range jobs {
						if matchesTransferPage(job, index) {
							count++
						}
					}
					if count > 0 {
						item.Children(func() { ui.Textf(c, "%d", count).TextColor(theme.TextMuted) })
					}
				}
			})
		}).Grow(1).Background(c.Theme().Background)
		if w.accounts != nil {
			ui.Divider(c)
			ui.MenuButton(c, "账号与设置", w.accountMenu)
		}
		if previous != w.preferences.Page {
			if f := w.files[app.Provider(previous)]; f != nil {
				f.directory.SetSelection(nil)
				f.syncSelection()
			}
			if providerTitle(w.preferences.Page) != "" {
				w.preferences.RecentProvider = w.preferences.Page
				w.allProviders = false
				if f := w.files[app.Provider(w.preferences.Page)]; f != nil {
					w.ensureDirectory(f)
				}
			} else {
				w.lastTransfer = w.preferences.Page
			}
		}
	})
}

func (w *Workspace) content(c *ui.Context, width float32, jobs []app.TransferJob) {
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
			if workspaceToolbarButton(c, sidebar, sidebarIcon).Clicked() {
				w.toggleSidebar()
			}
			ui.Text(c, title).Bold().SingleLine()
			ui.Spacer(c)
			if f := w.files[app.Provider(w.preferences.Page)]; f != nil && w.accounts.Session(f.directory.Provider()).State == app.LoggedIn {
				w.directorySearch(c, f)
			}
			if index >= 0 {
				if w.jobs != nil {
					w.transferBatchToolbar(c, w.visibleTransfers(jobs, index))
					if width >= 550 && ui.Button(c, "添加链接").Clicked() {
						w.showShare()
					}
					ui.Select(c, &w.transfer.direction, []string{"全部", "上传", "下载"}).Label("传输方向").Width(72)
				}
				searchWidth := float32(160)
				if width < 540 {
					searchWidth = 120
				}
				search := ui.TextInput(c, &w.transferSearch).Label("搜索任务").Placeholder("搜索任务").Width(searchWidth)
				if w.focusSearch {
					search.Focus()
					w.focusSearch = false
				}
				detailsLabel := "显示详情"
				if w.preferences.DetailsOpen && width >= 640 {
					detailsLabel = "隐藏详情"
				}
				if workspaceToolbarButton(c, detailsLabel, detailsIcon).Disabled(width < 640 && !w.preferences.DetailsOpen && w.preferences.SidebarHidden).Clicked() {
					windowWidth, _ := c.Size()
					w.toggleDetails(windowWidth)
				}
			}
		}).Height(48).Padding(0, 8, 0, titlePadding).DragWindow()
		if index < 0 {
			w.fileLanding(c, title, width)
			return
		}
		if w.preferences.DetailsOpen && width >= 640 {
			details := min(w.preferences.DetailsWidth, width/2, width-329)
			listWidth := width - details - 1
			split := ui.Split(c, &listWidth, func() { w.transferRows(c, jobs, index) }, func() {
				w.transferDetails(c, jobs, index)
			}).Grow(1)
			if split.Changed() {
				w.preferences.DetailsWidth = min(max(width-listWidth-1, 280), width/2, width-329)
			}
		} else {
			w.transferRows(c, jobs, index)
		}
	})
}

func (w *Workspace) fileLanding(c *ui.Context, title string, width float32) {
	provider := app.Provider(w.preferences.Page)
	f := w.files[provider]
	if f != nil {
		w.directoryToolbar(c, f, width)
		w.uploadDraftBar(c, f)
	} else {
		ui.Toolbar(c, func() {
			workspaceToolbarButton(c, "返回", backIcon).Disabled(true)
			ui.Text(c, "根目录")
		})
	}
	session := app.AccountSession{}
	if w.accounts != nil {
		session = w.accounts.Session(provider)
	}
	if session.State == app.LoggedIn && f != nil {
		w.directoryBody(c, f)
		return
	}
	ui.Column(c).Grow(1).FillWidth().Center().Gap(8).Padding(16).Children(func() {
		switch session.State {
		case app.Checking:
			ui.Text(c, "正在校验"+title).TextColor(c.Theme().TextMuted)
		case app.Expired, app.AccountProblem:
			ui.Text(c, session.Problem).TextColor(c.Theme().Danger)
			ui.Row(c).Gap(8).Children(func() {
				if session.State == app.AccountProblem && ui.Button(c, "重试").Clicked() {
					w.restoreAccount(provider)
				}
				if ui.Button(c, "重新登录").Clicked() {
					w.showLogin(provider)
				}
			})
		default:
			ui.Icon(c, accountIcon).FontSize(40).TextColor(c.Theme().TextMuted).AccessHidden(true)
			ui.Text(c, "登录"+title).FontSize(15).Bold().TextColor(c.Theme().TextMuted).Margin(12, 0, 0, 0)
			if ui.Button(c, "登录").Disabled(w.accounts == nil).Clicked() {
				w.showLogin(provider)
			}
		}
		if problem := w.accountProblem[provider]; problem != "" {
			ui.Text(c, problem).TextColor(c.Theme().Danger)
		}
	})
}

func (w *Workspace) transferLanding(c *ui.Context, index int) {
	title, icon := transferPages[index].empty, transferPages[index].icon
	searching := strings.TrimSpace(w.transferSearch) != ""
	logins := []app.Provider(nil)
	if searching {
		title, icon = "试试其他关键词", searchIcon
	} else if w.accounts != nil && w.jobs != nil && len(w.jobs.Snapshot()) == 0 {
		baidu := w.accounts.Session(app.Baidu)
		quark := w.accounts.Session(app.Quark)
		if baidu.State != app.LoggedIn && baidu.State != app.Checking &&
			quark.State != app.LoggedIn && quark.State != app.Checking {
			title, icon = transferPages[0].empty, transferPages[0].icon
			logins = []app.Provider{app.Baidu, app.Quark}
			if !w.allProviders {
				logins = []app.Provider{app.Provider(w.preferences.RecentProvider)}
			}
		}
	}
	ui.Column(c).Grow(1).FillWidth().Center().Gap(8).Children(func() {
		workspaceEmptyLabel(c, title, icon)
		if len(logins) != 0 {
			ui.Row(c).Gap(8).Children(func() {
				for _, provider := range logins {
					if ui.Button(c, "登录"+providerTitle(string(provider))).Clicked() {
						w.showLogin(provider)
					}
				}
			})
		} else if w.jobs != nil && index == 0 && !searching && ui.Button(c, "添加链接").Clicked() {
			w.showShare()
		}
	})
}

func workspaceEmptyLabel(c *ui.Context, title string, icon *ui.SVG) {
	ui.Icon(c, icon).FontSize(38).TextColor(c.Theme().TextMuted).AccessHidden(true)
	ui.Text(c, title).FontSize(15).Bold().TextColor(c.Theme().TextMuted)
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
