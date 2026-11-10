package ui

import (
	"testing"

	"github.com/egoist/mygo/ui"
)

func TestShareEnterWaitsForCompositionBeforeParsing(t *testing.T) {
	workspace := NewWorkspace(Preferences{})
	prompt := &sharePrompt{}
	window := ui.NewTester(func(c *ui.Context) { workspace.shareFields(c, prompt) }, 480, 100)
	window.Frame()
	window.Compose("fenxiang", 8)
	window.Key(0, ui.KeyEnter)
	if prompt.problem != "" || prompt.opening {
		t.Fatalf("候选确认不应解析分享链接: %q", prompt.problem)
	}
	window.Key(ui.Cmd, ui.KeyA)
	window.Compose("fenxiang", 8)
	window.Type("分享链接")
	window.Key(0, ui.KeyEnter)
	if prompt.problem == "" || prompt.opening {
		t.Fatal("提交候选后再次按 Enter，应校验已提交的文本")
	}
}
