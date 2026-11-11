package main

import (
	"context"
	"errors"
	"sync/atomic"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

// updateCommand shares one check/install session between the menu and scheduled checks.
func updateCommand(ctx context.Context, window *mygo.Window, restart func(), hasActiveWork, automatic func() bool) func() {
	var busy atomic.Bool
	prepared := false
	message := func(title, detail string) {
		if ctx.Err() == nil {
			_, _ = mygo.Dialog.Message(mygo.MessageOptions{
				Parent: mygo.FocusedWindow(), Title: "Ferry Drive", Message: title, Detail: detail, Buttons: []string{"好"},
			})
		}
	}
	restartWhenIdle := func() {
		var waiting bool
		mygo.RunOnMain(func() {
			if ctx.Err() != nil {
				return
			}
			waiting = hasActiveWork()
			if !waiting {
				restart()
			}
		})
		if waiting {
			message("更新已下载", "传输完成后，再点一次「检查更新…」即可重新启动。")
		}
	}
	check := func(manual bool) {
		if !busy.CompareAndSwap(false, true) {
			return
		}
		defer busy.Store(false)
		if prepared {
			if manual {
				restartWhenIdle()
			}
			return
		}

		checkCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		var checking *mygo.Window
		if manual {
			checking = showUpdateProgress("正在检查更新")
		}
		update, err := mygo.Updater.Check(checkCtx)
		if checking != nil {
			checking.Close()
		}
		switch {
		case errors.Is(err, mygo.ErrUpdatesDisabled):
			if manual {
				message("此安装无法应用内更新", "请将 Ferry Drive 安装到可写入的位置，或从发布页获取新版。")
			}
			return
		case err != nil:
			if manual {
				message("检查更新失败", err.Error())
			}
			return
		case update == nil:
			if manual {
				message("已是最新版", "当前版本为 "+mygo.App.Version()+"。")
			}
			return
		}
		if ctx.Err() != nil {
			return
		}
		choice, err := mygo.Dialog.Message(mygo.MessageOptions{
			Parent: mygo.FocusedWindow(), Title: "Ferry Drive", Message: "发现新版本 " + update.Version,
			Detail:  "下载并验证后，应用将在没有活动传输时重新启动。",
			Buttons: []string{"安装更新", "稍后"}, CancelButton: 1,
		})
		if err != nil || choice.Button != 0 || ctx.Err() != nil {
			return
		}
		progress := showUpdateProgress("正在下载和验证更新")
		err = update.Install(ctx, nil)
		if progress != nil {
			progress.Close()
		}
		if err != nil {
			message("安装更新失败", err.Error())
			return
		}
		prepared = true
		restartWhenIdle()
	}

	go func() {
		timer := time.NewTimer(10 * time.Second)
		defer timer.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-timer.C:
				if automatic() {
					check(false)
				}
				timer.Reset(24 * time.Hour)
			}
		}
	}()
	return func() {
		if !window.IsVisible() && mygo.FocusedWindow() == nil {
			window.Show()
		}
		go check(true)
	}
}

func showUpdateProgress(title string) *mygo.Window {
	var progress *mygo.Window
	mygo.RunOnMain(func() {
		progress = mygo.NewWindow(mygo.WindowOptions{
			Title: "Ferry Drive", Width: 320, Height: 150, DisableResize: true, DisableClose: true,
			Content: ui.View(func(c *ui.Context) {
				ui.Column(c).Fill().Center().Gap(12).Children(func() {
					ui.Spinner(c).Label(title)
					ui.Text(c, title).AccessHidden(true)
				})
			}),
		})
		progress.Show()
	})
	return progress
}
