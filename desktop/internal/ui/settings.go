package ui

import (
	"bytes"
	"context"
	"math"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
	"github.com/yjcdon/ferry-drive/desktop/internal/app"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

// SettingsWindowOptions connects the settings window to the workspace's
// existing account actions and notifies the app of committed settings.
type SettingsWindowOptions struct {
	InitialError   error
	ShowLogin      func(app.Provider)
	AccountChanged func(app.Provider)
	Changed        func()
	Closed         func()
	QuitPending    func() bool
}

type settingsWindow struct {
	window   *mygo.Window
	model    *app.SettingsModel
	accounts *app.Accounts
	opts     SettingsWindowOptions
	ctx      context.Context
	cancel   context.CancelFunc

	tab                    int
	saving, closeAfterSave bool
	chooser                func()
	problem                string
	folderProblem          string
	accountProblem         map[app.Provider]string
	accountBusy            map[app.Provider]bool
	logoutProvider         app.Provider
	confirmLogout          bool

	uploadRate, downloadRate       string
	rateProblem                    [2]string
	rateFocused                    bool
	baiduFolder, quarkFolder       string
	proxyMode                      platform.ProxyMode
	host, port, username, password string
	proxyFocused                   bool
	proxyPortProblem               string
}

// OpenSettings opens the four native settings categories in a dedicated window.
func OpenSettings(ctx context.Context, model *app.SettingsModel, accounts *app.Accounts, options SettingsWindowOptions) *mygo.Window {
	s := &settingsWindow{
		model: model, accounts: accounts, opts: options, tab: model.Values().SelectedTab,
		accountProblem: make(map[app.Provider]string), accountBusy: make(map[app.Provider]bool),
	}
	s.ctx, s.cancel = context.WithCancel(ctx)
	if options.InitialError != nil {
		s.problem = options.InitialError.Error()
	}
	s.reloadDraft()
	s.window = mygo.NewWindow(mygo.WindowOptions{
		Title: "设置", Width: 480, Height: 450, DisableResize: true,
		Content: ui.View(s.content),
	})
	s.window.OnClose(func(e *mygo.CloseEvent) {
		if s.saving {
			s.closeAfterSave = true
			e.PreventDefault()
			return
		}
		if s.flushDraft(s.tab) {
			s.closeAfterSave = true
			e.PreventDefault()
		}
	})
	s.window.OnClosed(func() {
		s.cancel()
		if s.chooser != nil {
			s.chooser()
		}
		s.password = ""
		if s.opts.Closed != nil {
			s.opts.Closed()
		}
	})
	s.checkDirectory()
	return s.window
}

func (s *settingsWindow) reloadDraft() {
	v := s.model.Values()
	s.uploadRate = strconv.FormatInt(v.UploadBytesPerSecond/1024, 10)
	s.downloadRate = strconv.FormatInt(v.DownloadBytesPerSecond/1024, 10)
	s.baiduFolder, s.quarkFolder = v.Baidu.TransferFolder, v.Quark.TransferFolder
	proxy, password := s.model.Proxy()
	s.proxyMode, s.host, s.username, s.password = proxy.Mode, proxy.Host, proxy.Username, password
	s.port = ""
	if proxy.Port != nil {
		s.port = strconv.Itoa(*proxy.Port)
	}
	s.proxyFocused, s.rateFocused = false, false
}

func (s *settingsWindow) content(c *ui.Context) {
	ui.Column(c).Fill().Background(c.Theme().Background).Children(func() {
		next := s.tab
		ui.Row(c).Padding(12, 18).Justify(ui.Center).Children(func() {
			if ui.Tabs(c, &next, "传输", "网盘", "网络", "账号").Disabled(s.saving).Changed() {
				s.flushDraft(next)
			}
		})
		ui.Divider(c)
		ui.Scroll(c).Grow(1).FillWidth().Children(func() {
			ui.Column(c).Padding(14, 18).Gap(12).FillWidth().Children(func() {
				switch s.tab {
				case 0:
					s.transfer(c)
				case 1:
					s.netdisks(c)
				case 2:
					s.network(c)
				case 3:
					s.accountSettings(c)
				}
				if s.problem != "" {
					ui.Text(c, s.problem).TextColor(c.Theme().Danger)
				}
			})
		})
	})
	if s.confirmLogout && ui.AlertDialog(c, &s.confirmLogout,
		"退出"+providerTitle(string(s.logoutProvider))+"？",
		"退出后可以重新登录以继续使用该账号。", "取消", "退出登录") == 1 {
		s.logout(s.logoutProvider)
	}
}

func settingsGroup(c *ui.Context, title string, fn func()) {
	if title != "" {
		ui.Text(c, title).Bold()
	}
	ui.Column(c).FillWidth().Padding(10).Gap(8).Radius(8).Background(c.Theme().Surface).Children(fn)
}

func settingsRow(c *ui.Context, label string, fn func()) {
	ui.Row(c).FillWidth().AlignItems(ui.Center).Gap(10).Children(func() {
		ui.Text(c, label)
		ui.Spacer(c)
		fn()
	})
}

func settingsStepper(c *ui.Context, label, accessName string, value, maxValue int, disabled bool) (int, bool) {
	next := float64(value)
	changed := false
	settingsRow(c, label, func() {
		ui.Text(c, strconv.Itoa(value)).AccessHidden(true)
		changed = ui.Stepper(c, &next, 1, float64(maxValue), 1).Label(accessName).Disabled(disabled).Changed()
	})
	return int(next), changed
}

func (s *settingsWindow) transfer(c *ui.Context) {
	v := s.model.Values()
	folder := v.DownloadDirectory.Path
	directoryLabel := "下载"
	if folder != "" {
		directoryLabel = filepath.Base(folder)
	}
	settingsGroup(c, "", func() {
		settingsRow(c, "下载目录", func() {
			ui.MenuButton(c, directoryLabel, func(menu *ui.Menu) {
				if menu.Item("下载").Chosen() {
					s.saveValues(func(v *app.SettingsValues) { v.DownloadDirectory = platform.LocalReference{} }, func() { s.folderProblem = "" })
				}
				if folder != "" {
					menu.Item(directoryLabel).Disabled(true)
				}
				menu.Separator()
				if menu.Item("其他…").Chosen() {
					s.chooseDirectory()
				}
			}).Label("下载目录").Value(directoryLabel).Tooltip(folder).Disabled(s.saving || s.chooser != nil)
		})
		if s.folderProblem != "" {
			ui.Text(c, s.folderProblem).TextColor(c.Theme().Warning)
		}
	})
	settingsGroup(c, "", func() {
		if next, ok := settingsStepper(c, "同时下载文件数", "同时下载文件数", v.MaxConcurrentFiles, v.AllowedConcurrentFiles(), s.saving); ok {
			s.saveValues(func(v *app.SettingsValues) { v.MaxConcurrentFiles = next }, nil)
		}
		if next, ok := settingsStepper(c, "同时上传任务数", "同时上传任务数", v.MaxConcurrentUploads, app.MaxUploadTasks, s.saving); ok {
			s.saveValues(func(v *app.SettingsValues) { v.MaxConcurrentUploads = next }, nil)
		}
	})
	focused, submitted := false, false
	settingsGroup(c, "", func() {
		for i, entry := range []struct {
			label string
			rate  *string
		}{{"上传限速", &s.uploadRate}, {"下载限速", &s.downloadRate}} {
			settingsRow(c, entry.label, func() {
				input := ui.TextInput(c, entry.rate).Label(entry.label).Width(100).Disabled(s.saving).Error(s.rateProblem[i])
				focused = input.Focused() || focused
				submitted = input.Submitted() || submitted
				ui.Text(c, "KiB/s").TextColor(c.Theme().TextMuted)
			})
			if s.rateProblem[i] != "" {
				ui.Text(c, s.rateProblem[i]).TextColor(c.Theme().Danger)
			}
		}
		ui.Text(c, "0 表示不限速，1 KiB/s = 1024 字节/秒。").TextColor(c.Theme().TextMuted)
	})
	if submitted || s.rateFocused && !focused && !s.saving {
		s.flushDraft(s.tab)
	}
	s.rateFocused = focused
	settingsGroup(c, "", func() {
		label := "每个上传文件的并发分片"
		if next, ok := settingsStepper(c, label, label, v.UploadPartsPerFile, app.MaxUploadParts, s.saving); ok {
			s.saveValues(func(v *app.SettingsValues) { v.UploadPartsPerFile = next }, nil)
		}
		ui.Text(c, "适用于百度和夸克。增加分片并发可提高上传速度，也会增加内存使用。").TextColor(c.Theme().TextMuted)
	})
	settingsGroup(c, "", func() {
		detect := v.DetectsCopiedLinks
		if ui.Toggle(c, &detect, "检测剪贴板中的分享链接").Disabled(s.saving).Changed() {
			s.saveValues(func(v *app.SettingsValues) { v.DetectsCopiedLinks = detect }, nil)
		}
	})
}

func (s *settingsWindow) chooseDirectory() {
	s.chooser = platform.ChooseDownloadFolder(s.window, func(ref platform.LocalReference, err error) {
		s.window.Update(func() {
			s.chooser = nil
			if err != nil {
				s.folderProblem = err.Error()
				return
			}
			if ref.Path != "" {
				s.saveValues(func(v *app.SettingsValues) { v.DownloadDirectory = ref }, func() { s.folderProblem = "" })
			}
		})
	})
}

func (s *settingsWindow) checkDirectory() {
	before := s.model.Values().DownloadDirectory
	go func() {
		err := s.model.CheckDownloadDirectory(s.ctx)
		s.window.Update(func() {
			current := s.model.Values().DownloadDirectory
			if err != nil && s.ctx.Err() == nil && current.Path == before.Path && bytes.Equal(current.Bookmark, before.Bookmark) {
				s.folderProblem = err.Error()
			}
		})
	}()
}

func (s *settingsWindow) netdisks(c *ui.Context) {
	v := s.model.Values()
	for _, entry := range []struct {
		provider app.Provider
		folder   *string
		hint     string
	}{
		{app.Baidu, &s.baiduFolder, "/Ferry"}, {app.Quark, &s.quarkFolder, "/Ferry Plus"},
	} {
		cfg := v.Disk(entry.provider)
		title := providerTitle(string(entry.provider))
		settingsGroup(c, title, func() {
			settingsRow(c, "转存目录", func() {
				if ui.TextInput(c, entry.folder).Label(title + "转存目录").Placeholder(entry.hint).Width(200).
					Disabled(s.saving).Submitted() {
					s.flushDraft(s.tab)
				}
			})
			cleanup := cfg.CleanupAfterDownload
			if ui.Toggle(c, &cleanup, "下载完成后清理转存文件").Label(title + "下载完成后清理转存文件").Disabled(s.saving).Changed() {
				s.saveValues(func(v *app.SettingsValues) {
					if entry.provider == app.Baidu {
						v.Baidu.CleanupAfterDownload = cleanup
					} else {
						v.Quark.CleanupAfterDownload = cleanup
					}
				}, nil)
			}
			if next, ok := settingsStepper(c, "每个文件的连接数", title+"每个文件的连接数", cfg.ConnectionsPerFile, v.AllowedConnections(), s.saving); ok {
				s.saveValues(func(v *app.SettingsValues) {
					if entry.provider == app.Baidu {
						v.Baidu.ConnectionsPerFile = next
					} else {
						v.Quark.ConnectionsPerFile = next
					}
				}, nil)
			}
		})
	}
}

func (s *settingsWindow) network(c *ui.Context) {
	focused, submitted, changed := false, false, false
	settingsGroup(c, "", func() {
		settingsRow(c, "代理", func() {
			mode := "使用系统设置"
			if s.proxyMode == platform.ProxySOCKS5 {
				mode = "SOCKS5"
			}
			if ui.Select(c, &mode, []string{"使用系统设置", "SOCKS5"}).Label("代理").Disabled(s.saving).Changed() {
				s.proxyMode = platform.ProxySystem
				if mode == "SOCKS5" {
					s.proxyMode = platform.ProxySOCKS5
				}
				changed = true
			}
		})
		if s.proxyMode == platform.ProxySOCKS5 {
			for _, entry := range []struct {
				label, hint string
				value       *string
			}{
				{"服务器", "127.0.0.1", &s.host}, {"端口", "1080", &s.port}, {"用户名", "可选", &s.username}, {"密码", "可选", &s.password},
			} {
				settingsRow(c, entry.label, func() {
					input := ui.TextInput(c, entry.value).Label(entry.label).Placeholder(entry.hint).Width(200).Disabled(s.saving)
					if entry.value == &s.password {
						input.Password()
					}
					if entry.value == &s.port {
						if input.Changed() {
							s.proxyPortProblem = ""
						}
						input.Error(s.proxyPortProblem)
					}
					focused = input.Focused() || focused
					submitted = input.Submitted() || submitted
				})
			}
			if s.proxyPortProblem != "" {
				ui.Text(c, s.proxyPortProblem).TextColor(c.Theme().Danger)
			}
			cfg, password := s.model.Proxy()
			if cfg.Mode == platform.ProxySOCKS5 && (cfg.Host != "" || cfg.Port != nil || cfg.Username != "" || password != "") {
				if problem := cfg.Problem(password); problem != nil {
					ui.Text(c, problem.Error()+"当前使用系统代理设置。").TextColor(c.Theme().Warning)
				}
			}
		}
	})
	ui.Text(c, "网盘请求和文件下载使用这个代理。").TextColor(c.Theme().TextMuted)
	if changed || submitted || s.proxyFocused && !focused && !s.saving {
		s.flushDraft(s.tab)
	}
	s.proxyFocused = focused
}

func (s *settingsWindow) accountSettings(c *ui.Context) {
	for _, entry := range providers {
		provider := app.Provider(entry.id)
		session := s.accounts.Session(provider)
		settingsGroup(c, entry.title, func() {
			if session.ID != "" {
				name := session.Name
				if name == "" && provider == app.Baidu {
					name = "百度账号"
				}
				settingsRow(c, "账号名称", func() { ui.Text(c, name).TextColor(c.Theme().TextMuted) })
			}
			status := "待登录"
			switch session.State {
			case app.Checking:
				status = "正在校验"
			case app.LoggedIn:
				status = "已登录"
			case app.Expired:
				status = "登录已失效"
			case app.AccountProblem:
				status = "登录校验未完成"
			}
			settingsRow(c, "状态", func() { ui.Text(c, status).TextColor(c.Theme().TextMuted) })
			if session.Problem != "" {
				ui.Text(c, session.Problem).TextColor(c.Theme().Warning)
			}
			if problem := s.accountProblem[provider]; problem != "" {
				ui.Text(c, problem).TextColor(c.Theme().Danger)
			}
			ui.Row(c).Gap(8).Children(func() {
				ui.Spacer(c)
				busy := s.accountBusy[provider] || session.State == app.Checking
				if session.ID == "" || session.State == app.Expired || session.State == app.AccountProblem {
					label := "登录"
					if session.ID != "" {
						label = "重新登录"
					}
					if ui.Button(c, label).Disabled(busy || s.opts.ShowLogin == nil).Clicked() {
						s.opts.ShowLogin(provider)
					}
				}
				if session.State == app.AccountProblem && session.ID != "" && ui.Button(c, "重试").Disabled(busy).Clicked() {
					go s.accounts.Restore(s.ctx, provider, func() { s.accountChanged(provider) })
				}
				if session.ID != "" && ui.Button(c, "退出登录").Disabled(busy).Clicked() {
					if provider == app.Baidu {
						s.logoutProvider, s.confirmLogout = provider, true
					} else {
						s.logout(provider)
					}
				}
			})
		})
	}
}

func (s *settingsWindow) logout(provider app.Provider) {
	s.accountBusy[provider] = true
	delete(s.accountProblem, provider)
	go func() {
		err := s.accounts.Logout(provider)
		s.window.Update(func() {
			delete(s.accountBusy, provider)
			if err != nil {
				s.accountProblem[provider] = err.Error()
			}
		})
		if err == nil {
			s.accountChanged(provider)
		}
	}()
}

func (s *settingsWindow) accountChanged(provider app.Provider) {
	if s.opts.AccountChanged != nil {
		s.opts.AccountChanged(provider)
	}
	s.window.Invalidate()
}

func (s *settingsWindow) saveValues(update func(*app.SettingsValues), applied func()) {
	s.save(func() error { return s.model.Update(update) }, applied, true)
}

// flushDraft commits textual values at the old tab's submit/leave boundary.
func (s *settingsWindow) flushDraft(next int) bool {
	if s.saving {
		return false
	}
	v := s.model.Values()
	var update func(*app.SettingsValues)
	var saveProxy func() error
	switch s.tab {
	case 0:
		upload, uploadOK := parseRate(s.uploadRate)
		download, downloadOK := parseRate(s.downloadRate)
		s.rateProblem = [2]string{}
		if !uploadOK {
			s.rateProblem[0] = "请输入整数限速。"
		}
		if !downloadOK {
			s.rateProblem[1] = "请输入整数限速。"
		}
		if !uploadOK {
			upload = v.UploadBytesPerSecond
		} else {
			s.uploadRate = strconv.FormatInt(upload/1024, 10)
		}
		if !downloadOK {
			download = v.DownloadBytesPerSecond
		} else {
			s.downloadRate = strconv.FormatInt(download/1024, 10)
		}
		if upload != v.UploadBytesPerSecond || download != v.DownloadBytesPerSecond {
			update = func(v *app.SettingsValues) { v.UploadBytesPerSecond, v.DownloadBytesPerSecond = upload, download }
		}
	case 1:
		if s.baiduFolder != v.Baidu.TransferFolder || s.quarkFolder != v.Quark.TransferFolder {
			baidu, quark := s.baiduFolder, s.quarkFolder
			update = func(v *app.SettingsValues) { v.Baidu.TransferFolder, v.Quark.TransferFolder = baidu, quark }
		}
	case 2:
		cfg, password := s.model.Proxy()
		port := strings.TrimSpace(s.port)
		if cfg.Mode != s.proxyMode || cfg.Host != strings.TrimSpace(s.host) || cfg.Username != strings.TrimSpace(s.username) ||
			password != s.password || port != settingPort(cfg.Port) {
			proxy := platform.ProxySettings{Mode: s.proxyMode, Host: s.host, Username: s.username}
			if n, err := strconv.Atoi(port); err == nil {
				proxy.Port = &n
			} else if port != "" {
				s.proxyPortProblem = "请输入有效的代理端口。"
			}
			nextPassword := s.password
			saveProxy = func() error { return s.model.SetProxy(proxy, nextPassword) }
		}
	}
	if next == s.tab && update == nil && saveProxy == nil {
		return false
	}
	s.save(func() error {
		if saveProxy != nil {
			if err := saveProxy(); err != nil {
				return err
			}
		}
		if update == nil && next == v.SelectedTab {
			return nil
		}
		return s.model.Update(func(values *app.SettingsValues) {
			if update != nil {
				update(values)
			}
			values.SelectedTab = next
		})
	}, func() {
		s.tab = next
		s.reloadDraft()
	}, update != nil || saveProxy != nil)
	return true
}

func (s *settingsWindow) save(work func() error, applied func(), notify bool) {
	if s.saving {
		return
	}
	s.saving = true
	go func() {
		err := work()
		s.window.Update(func() {
			s.saving = false
			s.problem = ""
			if err == nil {
				if applied != nil {
					applied()
				}
				if notify && s.opts.Changed != nil {
					s.opts.Changed()
				}
			} else {
				s.problem = "设置保存失败：" + err.Error()
			}
			if s.closeAfterSave {
				s.closeAfterSave = false
				if err == nil {
					s.window.Close()
				} else if s.opts.QuitPending != nil && s.opts.QuitPending() {
					s.window.Destroy()
				}
			}
		})
	}()
}

func parseRate(text string) (int64, bool) {
	n, err := strconv.ParseInt(strings.TrimSpace(text), 10, 64)
	if err != nil {
		return 0, false
	}
	return min(max(n, 0), math.MaxInt64/1024) * 1024, true
}

func settingPort(port *int) string {
	if port == nil {
		return ""
	}
	return strconv.Itoa(*port)
}
