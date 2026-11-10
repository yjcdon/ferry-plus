package ui

import (
	"runtime"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
)

// AttachSettings binds the settings window and its committed-change callback.
func (w *Workspace) AttachSettings(model *app.SettingsModel, readError error, changed func()) {
	w.settings, w.settingsReadError, w.settingsChanged = model, readError, changed
}

func (w *Workspace) showSettings() {
	w.window.Update(func() {
		if w.settingsWindow != nil {
			w.settingsWindow.Focus()
			return
		}
		w.settingsWindow = OpenSettings(w.ctx, w.settings, w.accounts, SettingsWindowOptions{
			InitialError:   w.settingsReadError,
			ShowLogin:      w.showLogin,
			AccountChanged: w.AccountChanged,
			Changed:        w.settingsChanged,
			Closed:         func() { w.settingsWindow = nil },
		})
	})
}

func (w *Workspace) showAbout() {
	if runtime.GOOS == "darwin" {
		mygo.App.ShowAboutPanel(mygo.AboutPanelOptions{
			ApplicationName: "Ferry Drive", ApplicationVersion: mygo.App.Version(),
		})
		return
	}
	if w.aboutWindow != nil {
		w.aboutWindow.Focus()
		return
	}
	w.aboutWindow = mygo.NewWindow(mygo.WindowOptions{
		Title: "关于 Ferry Drive", Width: 360, Height: 230, DisableResize: true,
		Content: ui.View(func(c *ui.Context) {
			ui.Column(c).Fill().Center().Gap(8).Background(c.Theme().Background).Children(func() {
				ui.Text(c, "Ferry Drive").FontSize(22).Bold()
				ui.Text(c, mygo.App.Version())
			})
		}),
	})
	w.aboutWindow.OnClosed(func() { w.aboutWindow = nil })
}
