package main

import (
	"log"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

func main() {
	window := &prototype{selected: -1}
	mygo.App.WhenReady(func() {
		mygo.NewWindow(mygo.WindowOptions{
			Title:     "Ferry Drive",
			Width:     960,
			Height:    640,
			MinWidth:  640,
			MinHeight: 400,
			Content:   ui.View(window.view),
		})
	})
	if err := mygo.App.Run(); err != nil {
		log.Fatal(err)
	}
}

// prototype exercises the native controls before the real workspace is wired.
type prototype struct {
	outline   ui.OutlineState[string]
	selected  int
	name      string
	confirmed string
	dialog    bool
}

func (p *prototype) view(c *ui.Context) {
	p.outline.List.Selected = &p.selected
	ui.Column(c).Fill().Padding(16).Gap(12).Background(c.Theme().Background).Children(func() {
		ui.Row(c).Gap(8).AlignItems(ui.Center).Children(func() {
			ui.TextInput(c, &p.name).Label("名称").Placeholder("输入名称").Grow(1)
			if ui.Button(c, "确认名称").Disabled(p.name == "").Clicked() {
				p.dialog = true
			}
		})
		ui.OutlineTable(c, &p.outline,
			[]ui.TableColumn{{Title: "名称"}, {Title: "大小", Width: 90}},
			[]string{"项目资料"},
			func(item string) []string {
				if item == "项目资料" {
					return []string{"使用说明.txt"}
				}
				return nil
			},
			func(item string, column int) {
				if column == 0 {
					ui.Text(c, item).SingleLine()
				} else if item == "使用说明.txt" {
					ui.Text(c, "1 KB")
				}
			},
		).Grow(1)
		if p.confirmed != "" {
			ui.Text(c, "已确认："+p.confirmed)
		}
		if ui.AlertDialog(c, &p.dialog, "确认名称", p.name, "取消", "确定") == 1 {
			p.confirmed = p.name
		}
	})
}
