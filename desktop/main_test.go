package main

import (
	"testing"

	"github.com/egoist/mygo/ui"
)

func TestNativePrototype(t *testing.T) {
	p := &prototype{selected: -1}
	window := ui.NewTester(p.view, 640, 400)
	click := func(label string) {
		t.Helper()
		if err := window.Click(label); err != nil {
			t.Fatal(err)
		}
	}

	click("项目资料")
	window.Key(0, ui.KeyRight)
	if !window.HasText("使用说明.txt") {
		t.Fatal("展开目录后应显示子文件")
	}
	window.Key(0, ui.KeyLeft)
	if window.HasText("使用说明.txt") {
		t.Fatal("折叠目录后应隐藏子文件")
	}

	click("名称")
	window.Type("测试文件")
	click("确认名称")
	window.Key(0, ui.KeyEscape)
	if p.dialog || p.confirmed != "" {
		t.Fatal("Esc 应关闭弹窗并保留未确认状态")
	}
	click("确认名称")
	window.Key(0, ui.KeyEnter)
	window.Frame()
	if !window.HasText("已确认：测试文件") {
		t.Fatal("确认后应显示输入的名称")
	}
}
