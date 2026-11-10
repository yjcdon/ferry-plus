package ui

import (
	"context"
	"errors"
	"net/url"
	"runtime"
	"strings"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
	"github.com/yjcdon/ferry-drive/desktop/internal/quark"
)

const (
	chromeUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36"
	baiduHome       = "https://pan.baidu.com/"
	baiduDiskMain   = "https://pan.baidu.com/disk/main"
	quarkHome       = "https://pan.quark.cn/"
	webViewRuntime  = "https://developer.microsoft.com/microsoft-edge/webview2/"
)

type loginWindow struct {
	window   *mygo.Window
	accounts *app.Accounts
	provider app.Provider
	changed  func()

	ctx    context.Context
	cancel context.CancelFunc
	view   *mygo.WebView
	stop   context.CancelFunc
	wake   chan struct{}

	loading, checking, saving bool
	useCookie, offerCookie    bool
	unavailable               bool
	seenBDUSS, diskMainAt     time.Time
	cookieText                string
	loadError, loginError     string
}

func openLogin(accounts *app.Accounts, provider app.Provider, changed, closed func()) *mygo.Window {
	l := &loginWindow{accounts: accounts, provider: provider, changed: changed}
	l.ctx, l.cancel = context.WithCancel(context.Background())
	opts := mygo.WindowOptions{
		Title: "登录" + providerTitle(string(provider)),
		Width: 800, Height: 700, MinWidth: 720, MinHeight: 600,
		Content: ui.View(l.content),
	}
	if provider == app.Quark {
		opts.Width, opts.Height, opts.MinWidth = 1000, 720, 800
	}
	l.window = mygo.NewWindow(opts)
	l.window.OnClose(func(e *mygo.CloseEvent) {
		if l.saving {
			e.PreventDefault()
		} else {
			l.cancel()
		}
	})
	l.window.OnClosed(func() {
		l.cancel()
		l.stopPage()
		closed()
	})
	l.startPage()
	return l.window
}

func (l *loginWindow) startPage() {
	l.loadError, l.loginError = "", ""
	l.unavailable = !mygo.WebViewAvailable()
	if l.unavailable {
		l.loadError = "网页登录组件不可用。"
		if runtime.GOOS == "windows" {
			l.loadError = "安装 Microsoft Edge WebView2 Runtime 后即可网页登录。"
		}
		return
	}

	session := mygo.NewEphemeralSession()
	view, err := l.window.NewWebView(mygo.WebViewOptions{Page: mygo.PageOptions{
		Session: session, UserAgent: chromeUserAgent, Untrusted: true, DevTools: mygo.DevToolsDisabled,
	}})
	if err != nil {
		l.loadError = "登录页打开失败，请重新加载。"
		return
	}
	l.view, l.loading = view, true
	page := view.Page()
	page.OnWillNavigate(func(e *mygo.NavigateEvent) {
		if !webURL(e.URL) {
			e.PreventDefault()
			return
		}
		l.loading, l.loadError = true, ""
		l.window.Invalidate()
	})
	page.OnDidNavigate(func(string) {
		l.loading = false
		l.window.Invalidate()
	})
	page.OnDidFinishLoad(func() { l.checkSoon() })
	page.OnDidFailLoad(func(err *mygo.LoadError) {
		if runtime.GOOS == "darwin" && (err.Code == -999 || err.Code == 102) {
			return
		}
		l.loading, l.loadError = false, "登录页加载失败："+err.Description
		l.window.Invalidate()
	})
	page.OnRenderProcessGone(func(string) {
		l.loading, l.loadError = false, "网页意外停止。"
		l.window.Invalidate()
	})
	page.SetWindowOpenHandler(func(req mygo.WindowOpenRequest) *mygo.WindowOptions {
		if webURL(req.URL) {
			l.window.Update(func() {
				if l.view == view {
					l.load(page, req.URL)
				}
			})
		}
		return nil
	})

	ctx, cancel := context.WithCancel(l.ctx)
	wake := make(chan struct{}, 1)
	l.stop, l.wake = cancel, wake
	go l.poll(ctx, session, wake)
	if l.provider == app.Baidu {
		l.load(page, baiduHome)
	} else {
		l.load(page, quarkHome)
	}
}

func (l *loginWindow) load(page *mygo.Page, target string) {
	l.loading, l.loadError = true, ""
	if err := page.LoadURL(target); err != nil {
		l.loading, l.loadError = false, "登录页打开失败，请重新加载。"
	}
}

func (l *loginWindow) stopPage() {
	if l.stop != nil {
		l.stop()
		l.stop = nil
	}
	if l.view != nil {
		l.view.Destroy()
		l.view = nil
	}
	l.wake = nil
}

func (l *loginWindow) checkSoon() {
	select {
	case l.wake <- struct{}{}:
	default:
	}
}

func (l *loginWindow) poll(ctx context.Context, session *mygo.Session, wake <-chan struct{}) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for ctx.Err() == nil {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-wake:
		}
		eligible := false
		mygo.RunOnMain(func() {
			eligible = ctx.Err() == nil && !l.checking && l.loginError == ""
		})
		if !eligible {
			continue
		}
		cookies, err := session.Cookies.List(mygo.CookieFilter{})
		mygo.RunOnMain(func() {
			if ctx.Err() != nil || l.checking || l.loginError != "" {
				return
			}
			if err != nil {
				l.loginError = "读取网页登录状态失败，请重试。"
				l.window.Invalidate()
				return
			}
			l.useWebCookies(cookies)
		})
	}
}

func (l *loginWindow) useWebCookies(cookies []mygo.Cookie) {
	now := time.Now()
	if l.provider == app.Quark {
		list := make([]quark.Cookie, 0, len(cookies))
		for _, item := range cookies {
			var expires *time.Time
			if !item.Expires.IsZero() {
				expires = &item.Expires
			}
			list = append(list, quark.Cookie{
				Name: item.Name, Value: item.Value, Domain: item.Domain, Path: item.Path, Expires: expires, Secure: item.Secure,
			})
		}
		if credential, err := quark.CredentialFromWebCookies(list); err == nil {
			l.validate(func() (*app.CheckedLogin, error) { return l.accounts.CheckQuark(l.ctx, credential) })
		}
		return
	}

	list := make([]baidu.BrowserCookie, 0, len(cookies))
	for _, item := range cookies {
		list = append(list, baidu.BrowserCookie{
			Cookie: baidu.Cookie{Name: item.Name, Value: item.Value},
			Domain: item.Domain, Path: item.Path, Expires: item.Expires,
		})
	}
	credential, err := baidu.CredentialFromCookies(list, now)
	switch {
	case err == nil:
		l.offerCookie = false
		l.validate(func() (*app.CheckedLogin, error) { return l.accounts.CheckBaidu(l.ctx, credential) })
	case errors.Is(err, baidu.ErrMissingSTOKEN):
		l.waitForSTOKEN(now)
	default:
		l.seenBDUSS = time.Time{}
	}
}

func (l *loginWindow) waitForSTOKEN(now time.Time) {
	if l.seenBDUSS.IsZero() {
		l.seenBDUSS = now
	}
	if !l.diskMainAt.IsZero() {
		if !l.offerCookie && now.Sub(l.diskMainAt) >= 10*time.Second {
			l.offerCookie = true
			l.window.Invalidate()
		}
		return
	}
	page := l.view.Page()
	current, _ := url.Parse(page.URL())
	if now.Sub(l.seenBDUSS) >= 5*time.Second && current != nil && current.Hostname() == "pan.baidu.com" {
		l.diskMainAt = now
		l.load(page, baiduDiskMain)
		l.window.Invalidate()
	}
}

func (l *loginWindow) validate(check func() (*app.CheckedLogin, error)) {
	l.checking, l.loginError = true, ""
	l.window.Invalidate()
	go func() {
		login, err := check()
		l.window.Update(func() {
			if l.ctx.Err() != nil {
				if login != nil {
					login.Discard()
				}
				return
			}
			if err != nil {
				l.checking, l.loginError = false, err.Error()
				return
			}
			l.saving = true
			go l.save(login)
		})
	}()
}

func (l *loginWindow) save(login *app.CheckedLogin) {
	err := l.accounts.Install(login)
	l.window.Update(func() {
		l.saving, l.checking = false, false
		if err != nil {
			l.loginError = err.Error()
			return
		}
		l.changed()
		l.window.Close()
	})
}

func (l *loginWindow) content(c *ui.Context) {
	ui.Column(c).Fill().Background(c.Theme().Background).Children(func() {
		if l.useCookie {
			l.cookieForm(c)
		} else {
			l.webForm(c)
		}
	})
	if c.Shortcut(0, ui.KeyEscape) {
		l.window.Update(l.window.Close)
	}
}

func (l *loginWindow) webForm(c *ui.Context) {
	if l.view != nil && l.loadError == "" {
		ui.WebView(c, l.view).Grow(1)
	} else {
		ui.Column(c).Grow(1).FillWidth().Center().Gap(8).Children(func() {
			ui.Text(c, l.loadError)
			if l.unavailable && runtime.GOOS == "windows" && ui.Button(c, "安装 WebView2 Runtime").Clicked() {
				go func() {
					if err := mygo.Shell.OpenExternal(webViewRuntime); err != nil {
						l.window.Update(func() { l.loadError = "打开 WebView2 下载页面失败，请重试。" })
					}
				}()
			}
		})
	}
	if l.loginError != "" || l.offerCookie {
		ui.Row(c).Padding(8, 16).Gap(8).AlignItems(ui.Center).Children(func() {
			if l.loginError != "" {
				ui.Text(c, l.loginError).Grow(1).TextColor(c.Theme().Danger)
				if ui.Button(c, "重试").Clicked() {
					l.loginError = ""
					l.checkSoon()
				}
			} else {
				ui.Text(c, "请使用 Cookie 登录以完成百度网盘登录。").Grow(1)
				if ui.Button(c, "粘贴 Cookie 登录").Clicked() {
					l.window.Update(func() {
						l.stopPage()
						l.useCookie = true
						l.window.SetMinimumSize(500, 360)
						l.window.SetContentSize(500, 380)
					})
				}
			}
		})
	}
	ui.Toolbar(c, func() {
		if ui.Button(c, "重新加载").Disabled(l.checking).Clicked() || !l.checking && c.Shortcut(ui.Cmd, ui.KeyR) {
			l.window.Update(func() {
				l.loginError, l.loadError = "", ""
				l.offerCookie = false
				l.seenBDUSS, l.diskMainAt = time.Time{}, time.Time{}
				if l.view == nil {
					l.startPage()
				} else {
					l.loading = true
					l.view.Page().Reload()
				}
			})
		}
		if l.checking {
			ui.Text(c, "正在校验")
		} else if l.loading {
			ui.Text(c, "正在加载")
		}
		ui.Spacer(c)
		if ui.Button(c, "取消").Disabled(l.saving).Clicked() {
			l.window.Update(l.window.Close)
		}
	}).Padding(12)
}

func (l *loginWindow) cookieForm(c *ui.Context) {
	ui.Column(c).Fill().Padding(16).Gap(8).Children(func() {
		ui.Text(c, "百度网盘 Cookie").Bold()
		ui.TextArea(c, &l.cookieText).Label("百度网盘 Cookie").Placeholder("BDUSS=…; STOKEN=…").Disabled(l.checking).Grow(1)
		ui.Text(c, "从 pan.baidu.com 的请求头复制包含 BDUSS 和 STOKEN 的 Cookie。").TextColor(c.Theme().TextMuted)
		if l.loginError != "" {
			ui.Text(c, l.loginError).TextColor(c.Theme().Danger)
		}
		ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
			if ui.Button(c, "网页登录").Disabled(l.checking).Clicked() {
				l.window.Update(func() {
					l.useCookie, l.cookieText = false, ""
					l.window.SetMinimumSize(720, 600)
					l.window.SetContentSize(800, 700)
					l.startPage()
				})
			}
			if l.checking {
				ui.Text(c, "正在校验")
			}
			ui.Spacer(c)
			if ui.Button(c, "取消").Disabled(l.saving).Clicked() {
				l.window.Update(l.window.Close)
			}
			if ui.PrimaryButton(c, "登录").Disabled(l.checking || strings.TrimSpace(l.cookieText) == "").Clicked() {
				credential, err := baidu.ParseCredential(l.cookieText)
				if err != nil {
					l.loginError = err.Error()
				} else {
					l.validate(func() (*app.CheckedLogin, error) { return l.accounts.CheckBaidu(l.ctx, credential) })
				}
			}
		})
	})
}

func webURL(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && u.Hostname() != "" && (u.Scheme == "http" || u.Scheme == "https")
}
