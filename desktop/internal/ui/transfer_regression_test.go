package ui

import (
	"slices"
	"testing"

	"github.com/egoist/mygo/ui"
	"github.com/yjcdon/ferry-drive/desktop/internal/app"
)

func TestTransferSearchFindsBatchFiles(t *testing.T) {
	job := app.TransferJob{Title: "旅行资料", AccountName: "我的账号", Items: []app.TransferItem{
		{RelativePath: "旅行资料/攻略/PLAN.PDF"}, {RelativePath: "旅行资料/车票.png"},
	}}
	for _, query := range []string{"", "旅行", "我的账号", "plan.pdf", "车票"} {
		if !matchesTransferSearch(job, query) {
			t.Errorf("batch search did not match %q", query)
		}
	}
	if matchesTransferSearch(job, "不存在") {
		t.Fatal("unrelated filename matched")
	}
}

func TestBatchRetryFiltersStatesAndAppearsInDetailsAndMenu(t *testing.T) {
	jobs := []app.TransferJob{
		{ID: "failed", Title: "下载失败", Direction: app.TransferDownload, State: app.TransferFailed},
		{ID: "check", Title: "上传待核对", Direction: app.TransferUpload, State: app.TransferNeedsCheck},
		{ID: "done", Title: "已完成", State: app.TransferCompleted},
		{ID: "cancel", State: app.TransferNeedsCheck, CancellationRequested: true},
		{ID: "stopping", State: app.TransferFailed, Stopping: true},
		{ID: "removing", State: app.TransferFailed, RemovalPending: true},
	}
	if got := transferRetryTargets(jobs); len(got) != 2 || got[0].ID != "failed" || got[1].ID != "check" {
		t.Fatalf("retry targets include an ineligible state: %v", got)
	}
	workspace := NewWorkspace(Preferences{})
	window := ui.NewTester(func(c *ui.Context) { workspace.transferBatchDetails(c, jobs) }, 320, 300)
	if !window.HasText("重试失败项") {
		t.Fatal("multi-selection details have no batch retry")
	}
	workspace.transfer.selection.Add("failed")
	workspace.transfer.selection.Add("check")
	window = ui.NewTester(func(c *ui.Context) {
		ui.Text(c, "任务行").ContextMenu(func(m *ui.Menu) { workspace.taskSelectionMenu(m, jobs[0], jobs) })
	}, 320, 300)
	if err := window.RightClick("任务行"); err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(window.Menu(), "重试失败项") {
		t.Fatalf("selected tasks have no batch retry in context menu: %v", window.Menu())
	}
}

func TestBatchContextMenuKeepsUnselectedAndDuplicateTasksSeparate(t *testing.T) {
	workspace := NewWorkspace(Preferences{})
	jobs := []app.TransferJob{
		{ID: "failed1", State: app.TransferFailed},
		{ID: "failed2", State: app.TransferFailed},
		{ID: "duplicate", State: app.TransferPaused, DuplicateOf: "original"},
	}
	workspace.transfer.selection.Add("failed1")
	workspace.transfer.selection.Add("failed2")
	window := ui.NewTester(func(c *ui.Context) {
		ui.Text(c, "未选中的重复任务").ContextMenu(func(m *ui.Menu) { workspace.taskSelectionMenu(m, jobs[2], jobs) })
	}, 320, 300)
	if err := window.RightClick("未选中的重复任务"); err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(window.Menu(), "仍然上传") || slices.Contains(window.Menu(), "重试失败项") {
		t.Fatalf("unselected row must keep its single-task action: %v", window.Menu())
	}
	workspace.transfer.selection.Add("duplicate")
	window = ui.NewTester(func(c *ui.Context) {
		ui.Text(c, "混合选择").ContextMenu(func(m *ui.Menu) { workspace.taskSelectionMenu(m, jobs[0], jobs) })
	}, 320, 300)
	if err := window.RightClick("混合选择"); err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(window.Menu(), "重试失败项") || slices.Contains(window.Menu(), "仍然上传") || slices.Contains(window.Menu(), "继续") {
		t.Fatalf("batch menu must not approve a duplicate upload: %v", window.Menu())
	}
}
