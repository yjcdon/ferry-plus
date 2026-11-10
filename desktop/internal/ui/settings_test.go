package ui

import (
	"math"
	"strconv"
	"testing"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
	"github.com/yjcdon/ferry-drive/desktop/internal/app"
	"github.com/yjcdon/ferry-drive/desktop/internal/store"
)

func TestSettingsFourNativePages(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("AppData", home)
	data, err := store.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer data.Close()
	model, err := app.LoadSettings(data)
	if err != nil {
		t.Fatal(err)
	}
	accounts := app.NewAccounts(data, nil)
	for i, labels := range [][]string{
		{"下载目录", "同时下载文件数", "同时上传任务数", "上传限速", "下载限速", "每个上传文件的并发分片", "检测剪贴板中的分享链接"},
		{"百度网盘", "夸克网盘", "转存目录", "每个文件的连接数"},
		{"代理", "使用系统设置", "网盘请求和文件下载使用这个代理。"},
		{"百度网盘", "夸克网盘", "状态", "待登录"},
	} {
		page := settingsWindow{model: model, accounts: accounts, tab: i}
		page.reloadDraft()
		window := ui.NewTester(page.content, 480, 450)
		for _, label := range labels {
			if !window.HasText(label) {
				t.Fatalf("标签页 %d 缺少 %q，界面为 %q", i, label, window.Texts())
			}
		}
	}
}

func TestSettingsRateKeepsIntegerKiBWithoutOverflow(t *testing.T) {
	for _, example := range []struct {
		input string
		bytes int64
		valid bool
	}{
		{" 12 ", 12 * 1024, true}, {"0", 0, true}, {"-1", 0, true}, {"2.5", 0, false},
		{strconv.FormatInt(math.MaxInt64, 10), math.MaxInt64 / 1024 * 1024, true},
	} {
		got, valid := parseRate(example.input)
		if got != example.bytes || valid != example.valid {
			t.Fatalf("限速 %q => %d %t", example.input, got, valid)
		}
	}
}

func TestSettingsTabsWithIconsKeepSelection(t *testing.T) {
	selected, changed := 0, -1
	window := ui.NewTester(func(c *ui.Context) {
		if settingsTabBar(c, &selected, false) {
			changed = selected
		}
	}, 480, 100)
	if err := window.Click("网络"); err != nil {
		t.Fatal(err)
	}
	if selected != 2 || changed != 2 {
		t.Fatalf("点击图标标签未报告页面切换，当前 %d，通知 %d", selected, changed)
	}
	window.Key(0, ui.KeyLeft)
	if selected != 1 || changed != 1 {
		t.Fatalf("方向键未报告页面切换，当前 %d，通知 %d", selected, changed)
	}
}

func TestTransferFolderCandidateEnterDoesNotSaveDraft(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("AppData", home)
	data, err := store.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer data.Close()
	model, err := app.LoadSettings(data)
	if err != nil {
		t.Fatal(err)
	}
	page := settingsWindow{model: model, window: &mygo.Window{}, tab: 1}
	page.reloadDraft()
	window := ui.NewTester(page.content, 480, 450)
	if err := window.Click("百度网盘转存目录"); err != nil {
		t.Fatal(err)
	}
	window.Key(ui.Cmd, ui.KeyA)
	window.Compose("zhuancun", 8)
	window.Key(0, ui.KeyEnter)
	if page.saving {
		t.Fatal("确认输入法候选时提前保存了转存目录")
	}
	window.Key(ui.Cmd, ui.KeyA)
	window.Compose("zhuancun", 8)
	window.Type("转存")
	window.Key(0, ui.KeyEnter)
	deadline := time.Now().Add(time.Second)
	for model.Values().Baidu.TransferFolder != "/转存" {
		if time.Now().After(deadline) {
			t.Fatalf("已提交的目录未保存: %q", model.Values().Baidu.TransferFolder)
		}
		time.Sleep(time.Millisecond)
	}
}
