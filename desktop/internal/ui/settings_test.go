package ui

import (
	"math"
	"strconv"
	"testing"

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
