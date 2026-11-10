package ui

import (
	"path/filepath"
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

func TestCompletedDownloadOffersTopLevelReveal(t *testing.T) {
	root := t.TempDir()
	folder := filepath.Join(root, "相册")
	file := filepath.Join(root, "笔记 (1).txt")
	job := app.TransferJob{ID: "download", Title: "下载样本", Direction: app.TransferDownload, State: app.TransferCompleted,
		Items: []app.TransferItem{
			{RelativePath: "相册/一.jpg", LocalPath: filepath.Join(folder, "一.jpg"), Complete: true},
			{RelativePath: "相册/子目录/二.jpg", LocalPath: filepath.Join(folder, "子目录", "二.jpg"), Complete: true},
			{RelativePath: "笔记.txt", LocalPath: file, Complete: true},
			{RelativePath: "已删除.txt", LocalPath: filepath.Join(root, "已删除.txt"), Trashed: true},
		}}
	if got := transferRevealPaths(job); !slices.Equal(got, []string{folder, file}) {
		t.Fatalf("reveal must deduplicate top-level paths and keep the actual renamed file: %v", got)
	}
	workspace := NewWorkspace(Preferences{})
	if label, command := workspace.primaryTransferAction(job); label != transferRevealLabel() || command == nil {
		t.Fatalf("completed download is missing its primary reveal action: %q", label)
	}
	window := ui.NewTester(func(c *ui.Context) { workspace.transferRow(c, job, []app.TransferJob{job}) }, 600, 150)
	if !window.HasText(transferRevealLabel()) {
		t.Fatal("completed download row has no reveal button")
	}
	if err := window.RightClick(job.Title); err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(window.Menu(), transferRevealLabel()) {
		t.Fatalf("row menu lacks reveal: %v", window.Menu())
	}
	job.Direction = app.TransferUpload
	if _, command := workspace.primaryTransferAction(job); command != nil {
		t.Fatal("completed upload must not offer download reveal")
	}
	job.Direction = app.TransferDownload
	for i := range job.Items {
		job.Items[i].Trashed = true
	}
	if _, command := workspace.primaryTransferAction(job); command != nil {
		t.Fatal("trashed download must not offer reveal")
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

func TestBatchPriorityOnlyOffersQueuedUploads(t *testing.T) {
	workspace := NewWorkspace(Preferences{})
	selected := []app.TransferJob{
		{ID: "upload", Direction: app.TransferUpload, State: app.TransferQueued},
		{ID: "running", Direction: app.TransferUpload, State: app.TransferRunning},
		{ID: "download", Direction: app.TransferDownload, State: app.TransferQueued},
		{ID: "waiting", Direction: app.TransferUpload, State: app.TransferWaitingAccount},
	}
	if got := prioritizedUploads(selected); len(got) != 1 || got[0].ID != "upload" {
		t.Fatalf("批量优先上传范围错误: %v", got)
	}
	window := ui.NewTester(func(c *ui.Context) { workspace.transferBatchDetails(c, selected) }, 320, 240)
	if !window.HasText("优先上传") {
		t.Fatal("选中排队上传时应显示优先上传")
	}
}

func TestTransferErrorCopyUsesSelectedErrors(t *testing.T) {
	jobs := []app.TransferJob{
		{ID: "failed", Title: "下载样本", State: app.TransferFailed, Error: "连接中断"},
		{ID: "done", Title: "完成样本", State: app.TransferCompleted},
		{ID: "second", Title: "上传样本", State: app.TransferFailed, Error: "源文件已移动"},
	}
	if got := transferErrorText(jobs); got != "下载样本：连接中断\n上传样本：源文件已移动" {
		t.Fatalf("复制文本包含错误的范围或顺序: %q", got)
	}
	workspace := NewWorkspace(Preferences{})
	workspace.transfer.selection.Add("failed")
	workspace.transfer.selection.Add("done")
	window := ui.NewTester(func(c *ui.Context) {
		ui.Text(c, "已选任务").ContextMenu(func(m *ui.Menu) { workspace.taskSelectionMenu(m, jobs[0], jobs) })
	}, 320, 100)
	if err := window.RightClick("已选任务"); err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(window.Menu(), "复制错误") {
		t.Fatalf("多选失败任务缺少复制错误: %v", window.Menu())
	}
}

func TestBatchCancelOnlyOffersActiveUploads(t *testing.T) {
	workspace := NewWorkspace(Preferences{})
	selected := []app.TransferJob{
		{ID: "waiting", Direction: app.TransferUpload, State: app.TransferWaitingAccount},
		{ID: "paused", Direction: app.TransferUpload, State: app.TransferPaused},
		{ID: "running-download", Direction: app.TransferDownload, State: app.TransferRunning},
		{ID: "finished", Direction: app.TransferUpload, State: app.TransferCompleted},
		{ID: "stopping", Direction: app.TransferUpload, State: app.TransferRunning, Stopping: true},
	}
	if got := cancelableUploads(selected); len(got) != 2 || got[0].ID != "waiting" || got[1].ID != "paused" {
		t.Fatalf("取消上传范围错误: %v", got)
	}
	window := ui.NewTester(func(c *ui.Context) { workspace.transferBatchDetails(c, selected) }, 320, 250)
	if !window.HasText("取消上传") {
		t.Fatal("多选详情缺少取消上传")
	}
}
