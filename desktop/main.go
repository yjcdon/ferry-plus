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
	transport.configure(settings.Proxy())
	defer transport.CloseIdleConnections()
	businessClient := &http.Client{Transport: transport, Timeout: 60 * time.Second}
	accounts := app.NewAccounts(data, businessClient)
	var notifyWindow atomic.Pointer[mygo.Window]
	transfers, err := app.NewTransfers(data, accounts, businessClient, app.TransferConfigFromSettings(settings.Values()), func() {
		if window := notifyWindow.Load(); window != nil {
			window.Invalidate()
		}
	})
	if err != nil {
		return err
	}
	defer transfers.Close()
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
			transport.configure(settings.Proxy())
			transfers.Configure(app.TransferConfigFromSettings(settings.Values()))
		})
		go accounts.Restore(ctx, app.Baidu, func() { workspace.AccountChanged(app.Baidu) })
		go accounts.Restore(ctx, app.Quark, func() { workspace.AccountChanged(app.Quark) })
		mygo.App.SetMenu(workspace.Menu(window))
	})
	if err := mygo.App.Run(); err != nil {
		return err
	}
	return data.Write("workspace", workspace.Preferences())
}
