package main

import (
	"context"
	"errors"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
	"github.com/yjcdon/ferry-drive/desktop/internal/app"
)

// updateCommand shares one check/install session between the menu and scheduled checks.
func updateCommand(ctx context.Context, window *mygo.Window, updateInstall *sync.Mutex, restart func(), closeTransfersIfIdle func() bool, settings *app.SettingsModel) func() {
	var state sync.Mutex
	var busy, checkingFeed, showResult bool
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
			waiting = !closeTransfersIfIdle()
			if !waiting {
				restart()
			}
		})
		if waiting {
			message("更新已下载", "传输完成后，再点一次「检查更新…」即可重新启动。")
		}
	}
	check := func(manual bool) {
		state.Lock()
		if busy {
			if manual && checkingFeed {
				showResult = true
			}
			state.Unlock()
			return
		}
		busy, checkingFeed, showResult = true, !prepared, manual
		state.Unlock()
		defer func() {
			state.Lock()
			busy, checkingFeed = false, false
			state.Unlock()
		}()
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
		if err == nil && ctx.Err() == nil {
			if saveErr := settings.Update(func(v *app.SettingsValues) { v.LastUpdateCheckUnix = time.Now().Unix() }); saveErr != nil {
				log.Printf("保存更新检查时间: %v", saveErr)
			}
		}
		state.Lock()
		manual, checkingFeed = showResult, false
		state.Unlock()
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
		if ctx.Err() != nil || !manual && settings.Values().DisableAutomaticUpdateChecks {
			return
		}
		detail := "下载并验证后，应用将在没有活动传输时重新启动。"
		if notes := []rune(strings.TrimSpace(update.Notes)); len(notes) != 0 {
			const maxNotes = 600
			if len(notes) > maxNotes {
				notes = append(notes[:maxNotes], '…')
			}
			detail = string(notes) + "\n\n" + detail
		}
		choice, err := mygo.Dialog.Message(mygo.MessageOptions{
			Parent: mygo.FocusedWindow(), Title: "Ferry Drive", Message: "发现新版本 " + update.Version,
			Detail:  detail,
			Buttons: []string{"安装更新", "稍后"}, CancelButton: 1,
		})
		if err != nil || choice.Button != 0 || ctx.Err() != nil {
			return
		}
		progress := showUpdateProgress("正在下载和验证更新")
		err = installUpdate(ctx, updateInstall, func(ctx context.Context) error { return update.Install(ctx, nil) })
		if progress != nil {
			progress.Close()
		}
		if errors.Is(err, context.DeadlineExceeded) {
			message("下载更新超时", "请检查网络连接后重试。")
			return
		}
		if err != nil {
			message("安装更新失败", err.Error())
			return
		}
		prepared = true
		restartWhenIdle()
	}

	go func() {
		const interval = 24 * time.Hour
		timer := time.NewTimer(10 * time.Second)
		defer timer.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-timer.C:
				values := settings.Values()
				if values.DisableAutomaticUpdateChecks {
					timer.Reset(interval)
				} else if wait := time.Until(time.Unix(values.LastUpdateCheckUnix, 0).Add(interval)); wait > 0 {
					timer.Reset(wait)
				} else {
					check(false)
					timer.Reset(interval)
				}
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

func installUpdate(ctx context.Context, barrier *sync.Mutex, apply func(context.Context) error) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	barrier.Lock()
	defer barrier.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	return apply(ctx)
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
