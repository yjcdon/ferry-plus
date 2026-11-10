package ui

import (
	"reflect"
	"testing"

	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
)

func TestWorkspaceNavigation(t *testing.T) {
	workspace := NewWorkspace(Preferences{})
	window := ui.NewTester(workspace.View, 960, 640)
	click := func(label string) {
		t.Helper()
		if err := window.Click(label); err != nil {
			t.Fatal(err)
		}
		window.Frame()
	}

	click("夸克网盘")
	if workspace.Preferences().RecentProvider != quarkPage || !window.HasText("登录夸克网盘") {
		t.Fatalf("切换后未显示夸克文件页，界面为 %q", window.Texts())
	}

	click("进行中")
	if !window.HasText("夸克网盘 · 进行中") {
		t.Fatalf("传输页未保留最近网盘，界面为 %q", window.Texts())
	}
	click("查看全部")
	if !window.HasText("进行中") || !workspace.allProviders {
		t.Fatalf("查看全部未保留传输分类，界面为 %q", window.Texts())
	}
	click("搜索任务")
	window.Type("测试")
	if !window.HasText("试试其他关键词") {
		t.Fatalf("搜索后未显示空结果，界面为 %q", window.Texts())
	}

	click("显示详情")
	if !window.HasText("选择任务查看详情") {
		t.Fatalf("未打开详情，界面为 %q", window.Texts())
	}
	window.SetSize(640, 400)
	if window.HasText("选择任务查看详情") || !window.HasText("试试其他关键词") {
		t.Fatalf("窄窗应收起详情并保留搜索结果，界面为 %q", window.Texts())
	}

	restored := NewWorkspace(workspace.Preferences())
	if !reflect.DeepEqual(restored.Preferences(), workspace.Preferences()) {
		t.Fatal("恢复后导航或分栏偏好发生变化")
	}
}

func TestUploadSourceRecoveryAppearsForAffectedItem(t *testing.T) {
	workspace := NewWorkspace(Preferences{})
	job := app.TransferJob{ID: "upload", Direction: app.TransferUpload, State: app.TransferFailed}
	item := app.TransferItem{RelativePath: "样本.txt", CanRebind: true, Error: "原文件已移动"}
	window := ui.NewTester(func(c *ui.Context) {
		workspace.transferDetailItem(c, job, item)
	}, 320, 200)
	if !window.HasText("重新选择源文件") || !window.HasText("原文件已移动") {
		t.Fatalf("缺少恢复操作或错误，界面为 %q", window.Texts())
	}
	job.State = app.TransferCompleted
	window.Frame()
	if window.HasText("重新选择源文件") {
		t.Fatal("已完成任务不应提供源文件重选")
	}
}
