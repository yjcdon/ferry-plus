package ui

import (
	"slices"
	"testing"

	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
)

func TestAccountMenuListsBothAccountsBeforeSettings(t *testing.T) {
	workspace := NewWorkspace(Preferences{})
	workspace.accounts = app.NewAccounts(nil, nil)
	workspace.settings = &app.SettingsModel{}
	tester := ui.NewTester(workspace.View, 960, 640)
	if err := tester.Click("账号与设置"); err != nil {
		t.Fatal(err)
	}
	want := []string{"百度网盘 · 待登录", "登录", "-", "夸克网盘 · 待登录", "登录", "-", "设置"}
	if got := tester.Menu(); !slices.Equal(got, want) {
		t.Fatalf("账号菜单 = %v，预期 %v", got, want)
	}
}
