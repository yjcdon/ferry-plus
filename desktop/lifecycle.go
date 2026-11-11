package main

import (
	"runtime"
	"sync"

	"github.com/egoist/mygo"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
	ferryui "github.com/yjcdon/ferry-drive/desktop/internal/ui"
)

func bindDesktop(window *mygo.Window, workspace *ferryui.Workspace, transfers *app.Transfers, updateInstall *sync.Mutex, cancel, beforeRestart func()) (restart func()) {
	quitting, ready := false, false
	show := func() {
		if !quitting {
			window.Show()
			window.Focus()
		}
	}
	window.OnClose(func(e *mygo.CloseEvent) {
		if !ready {
			e.PreventDefault()
			if !quitting {
				window.Hide()
			}
		}
	})
	mygo.App.OnActivate(func(visible bool) {
		if !visible {
			show()
		}
	})
	mygo.App.OnSecondInstance(func([]string, string) { show() })
	mygo.App.OnDidBecomeActive(workspace.DetectCopiedLink)
	window.OnShow(workspace.DetectCopiedLink)
	mygo.App.OnNotificationClick(func(id string) {
		show()
		workspace.ShowTransfer(id)
	})
	mygo.Power.OnSuspend(transfers.Suspend)
	mygo.Power.OnResume(transfers.Wake)

	var tray *mygo.Tray
	if runtime.GOOS == "windows" {
		menu := mygo.NewMenu([]*mygo.MenuItem{
			{Label: "打开 Ferry Drive", Click: func(*mygo.MenuItem, *mygo.Window) { show() }},
			{Label: "退出 Ferry Drive", Role: mygo.RoleQuit},
		})
		tray, _ = mygo.NewTray(mygo.TrayOptions{ID: "main", ToolTip: "Ferry Drive", Menu: menu})
	}
	prepareExit := func(finish func()) {
		if quitting {
			return
		}
		quitting = true
		workspace.PrepareQuit(func() {
			cancel()
			go func() {
				transfers.Close()
				// Cancellation stops the download. A file swap already underway must finish.
				updateInstall.Lock()
				updateInstall.Unlock()
				window.Update(func() {
					if tray != nil {
						tray.Destroy()
					}
					ready = true
					finish()
				})
			}()
		})
	}
	mygo.App.OnBeforeQuit(func(e *mygo.QuitEvent) {
		if !ready {
			e.PreventDefault()
			prepareExit(mygo.App.Quit)
		}
	})
	return func() {
		prepareExit(func() {
			beforeRestart()
			mygo.App.Relaunch()
		})
	}
}
