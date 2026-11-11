package main

import (
	"context"
	"errors"
	"io/fs"
	"log"
	"net/http"
	"runtime"
	"sync/atomic"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
	"github.com/yjcdon/ferry-drive/desktop/internal/store"
	ferryui "github.com/yjcdon/ferry-drive/desktop/internal/ui"
)

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() (err error) {
	mygo.App.SetName("Ferry Drive")
	if !mygo.App.RequestSingleInstanceLock() {
		return nil
	}
	data, err := store.Open()
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, data.Close()) }()

	var prefs ferryui.Preferences
	if err := data.Read("workspace", &prefs); err != nil && !errors.Is(err, fs.ErrNotExist) {
		log.Print(err)
		prefs = ferryui.Preferences{}
	}
	workspace := ferryui.NewWorkspace(prefs)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	settings, settingsErr := app.LoadSettings(data)
	transport := new(businessTransport)
	transport.proxyChange(settings.Proxy())()
	defer transport.CloseIdleConnections()
	businessClient := &http.Client{Transport: transport, Timeout: 60 * time.Second}
	accounts := app.NewAccounts(data, businessClient)
	accounts.OnExpired(workspace.AccountChanged)
	var notifyWindow atomic.Pointer[mygo.Window]
	var notifyQueued atomic.Bool
	transfers, err := app.NewTransfers(data, accounts, businessClient, app.TransferConfigFromSettings(settings.Values()), func() {
		if window := notifyWindow.Load(); window != nil && notifyQueued.CompareAndSwap(false, true) {
			window.Update(func() {
				notifyQueued.Store(false)
				workspace.TransfersChanged()
			})
		}
	})
	if err != nil {
		return err
	}
	defer transfers.Close()
	var restartSaveErr error
	savedForRestart := false
	mygo.App.WhenReady(func() {
		opts := mygo.WindowOptions{
			Title:     "Ferry Drive",
			Width:     960,
			Height:    640,
			MinWidth:  640,
			MinHeight: 400,
			StateKey:  "main",
			Content:   ui.View(workspace.View),
		}
		if runtime.GOOS == "darwin" {
			opts.TitleBarStyle = mygo.TitleBarHiddenInset
		}
		window := mygo.NewWindow(opts)
		notifyWindow.Store(window)
		workspace.AttachAccounts(ctx, window, accounts)
		workspace.AttachTransfers(transfers)
		workspace.AttachSettings(settings, settingsErr, func() {
			transfers.ChangeProxy(transport.proxyChange(settings.Proxy()))
			transfers.Configure(app.TransferConfigFromSettings(settings.Values()))
		})
		go accounts.Restore(ctx, app.Baidu, func() { workspace.AccountChanged(app.Baidu) })
		go accounts.Restore(ctx, app.Quark, func() { workspace.AccountChanged(app.Quark) })
		restart := bindDesktop(window, workspace, transfers, cancel, func() {
			restartSaveErr = errors.Join(data.Write("workspace", workspace.Preferences()), data.Close())
			savedForRestart = true
		})
		mygo.App.SetMenu(workspace.Menu(window, updateCommand(ctx, window, restart, transfers.HasActiveWork, func() bool {
			return !settings.Values().DisableAutomaticUpdateChecks
		})))
	})
	if err := mygo.App.Run(); err != nil || savedForRestart {
		return errors.Join(err, restartSaveErr)
	}
	return data.Write("workspace", workspace.Preferences())
}
