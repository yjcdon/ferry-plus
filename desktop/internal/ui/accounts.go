package ui

import (
	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
)

func (w *Workspace) accountMenu(menu *ui.Menu) {
	for index, entry := range providers {
		if index > 0 {
			menu.Separator()
		}
		provider := app.Provider(entry.id)
		session := w.accounts.Session(provider)
		name := session.Name
		if name == "" {
			name = "待登录"
		}
		menu.Item(entry.title + " · " + name).Disabled(true)
		switch session.State {
		case app.LoggedOut:
			if menu.Item("登录").ID(entry.id + ":login").Chosen() {
				w.showLogin(provider)
			}
		case app.Checking:
			menu.Item("正在校验").Disabled(true)
		case app.Expired, app.AccountProblem:
			if session.Problem != "" {
				menu.Item(session.Problem).Disabled(true)
			}
			if menu.Item("重新登录").ID(entry.id + ":login").Chosen() {
				w.showLogin(provider)
			}
			if session.State == app.AccountProblem && menu.Item("重试").ID(entry.id+":retry").Chosen() {
				w.restoreAccount(provider)
			}
		}
		if session.ID != "" && menu.Item("退出登录").ID(entry.id+":logout:"+session.ID).Disabled(w.loginWindows[provider] != nil).Chosen() {
			w.logoutProvider, w.confirmLogout = provider, true
		}
	}
	if w.settings != nil {
		menu.Separator()
		if menu.Item("设置").ID("settings").Chosen() {
			w.showSettings()
		}
	}
}

func (w *Workspace) showLogin(provider app.Provider) {
	w.window.Update(func() {
		if w.quitting {
			return
		}
		if existing := w.loginWindows[provider]; existing != nil {
			existing.Focus()
			return
		}
		delete(w.accountProblem, provider)
		w.loginWindows[provider] = openLogin(w.ctx, w.accounts, provider, func() { w.AccountChanged(provider) }, func() {
			delete(w.loginWindows, provider)
			w.finishPrepareQuit()
		})
	})
}

func (w *Workspace) restoreAccount(provider app.Provider) {
	go w.accounts.Restore(w.ctx, provider, func() { w.AccountChanged(provider) })
}

func (w *Workspace) logout(provider app.Provider) {
	delete(w.accountProblem, provider)
	go func() {
		err := w.accounts.Logout(provider)
		w.window.Update(func() {
			if err != nil {
				w.accountProblem[provider] = err.Error()
				w.preferences.Page = string(provider)
				w.preferences.RecentProvider = string(provider)
				w.allProviders = false
			} else {
				delete(w.preferences.DirectoryLocations, provider)
				w.AccountChanged(provider)
			}
		})
	}()
}
