package ui

import (
	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
)

func (w *Workspace) accountMenu(menu *ui.Menu) {
	for _, entry := range providers {
		provider := app.Provider(entry.id)
		session := w.accounts.Session(provider)
		menu.Submenu(entry.title, func(m *ui.Menu) {
			if session.Name != "" {
				m.Item(session.Name).Disabled(true)
			}
			switch session.State {
			case app.LoggedOut:
				if m.Item("登录").Chosen() {
					w.showLogin(provider)
				}
			case app.Checking:
				m.Item("正在校验").Disabled(true)
			case app.Expired, app.AccountProblem:
				if m.Item("重新登录").Chosen() {
					w.showLogin(provider)
				}
				if session.State == app.AccountProblem && m.Item("重试").Chosen() {
					w.restoreAccount(provider)
				}
			}
			if session.ID != "" && m.Item("退出登录").Disabled(w.loginWindows[provider] != nil).Chosen() {
				w.logoutProvider, w.confirmLogout = provider, true
			}
		})
	}
}

func (w *Workspace) showLogin(provider app.Provider) {
	w.window.Update(func() {
		if existing := w.loginWindows[provider]; existing != nil {
			existing.Focus()
			return
		}
		delete(w.accountProblem, provider)
		w.loginWindows[provider] = openLogin(w.accounts, provider, func() { w.AccountChanged(provider) }, func() {
			delete(w.loginWindows, provider)
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
