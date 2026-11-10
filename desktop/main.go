package main

import (
	"errors"
	"io/fs"
	"log"
	"runtime"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"

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
		mygo.App.SetMenu(workspace.Menu(window))
	})
	if err := mygo.App.Run(); err != nil {
		return err
	}
	return data.Write("workspace", workspace.Preferences())
}
