package ui

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/egoist/mygo/transfer"
	"github.com/egoist/mygo/ui"
	"github.com/yjcdon/ferry-drive/desktop/internal/app"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

func TestDirectoryDropOpensMixedLocalItems(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "中文 文件.txt")
	folder := filepath.Join(dir, "中文 文件夹")
	if err := os.WriteFile(file, []byte("upload sample"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(folder, 0o700); err != nil {
		t.Fatal(err)
	}
	data, err := transfer.FileData(file, folder)
	if err != nil {
		t.Fatal(err)
	}
	items, err := referencesFromDrop(transfer.Drop{Data: data})
	if err != nil || len(items) != 2 {
		t.Fatalf("drop produced %d references, error: %v", len(items), err)
	}
	for i, path := range []string{file, folder} {
		access, err := platform.OpenLocalItem(items[i])
		if err != nil {
			t.Fatal(err)
		}
		defer access.Close()
		want, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		got, err := os.Stat(access.Reference.Path)
		if err != nil || !os.SameFile(got, want) {
			t.Fatalf("reference %d resolved to %q, want %q (error: %v)", i, access.Reference.Path, path, err)
		}
	}
}

func TestDirectoryDropUsesWholeFolderRow(t *testing.T) {
	root := app.Quark.RootRef()
	folder := app.RemoteRef{Provider: app.Quark, ID: "folder"}
	file := app.RemoteRef{Provider: app.Quark, ID: "file"}
	var outline ui.OutlineState[app.RemoteRef]
	var got app.RemoteRef
	var folderBounds ui.Rect
	window := ui.NewTester(func(c *ui.Context) {
		// A top inset catches accidental use of element-relative rather than window coordinates.
		ui.Box(c).Height(40)
		var rows []directoryDropRow
		table := ui.OutlineTable(c, &outline, fileColumns, []app.RemoteRef{folder, file}, func(app.RemoteRef) []app.RemoteRef { return nil }, func(ref app.RemoteRef, column int) {
			if column == 0 {
				content := ui.Row(c).Gap(6).AlignItems(ui.Center).Children(func() {
					ui.Text(c, ref.ID).SingleLine()
				})
				if ref == folder {
					folderBounds = directoryDropRowBounds(c, content)
					rows = append(rows, directoryDropRow{ref, folderBounds})
				}
			} else {
				ui.Text(c, "—").SingleLine()
			}
		}).Grow(1)
		got = directoryTableDropTarget(c, table, rows, root)
	}, 800, 400)
	window.Frame()
	for _, x := range []float32{5, 160, 330, 510, 600, 790} {
		for _, y := range []float32{folderBounds.Y + 1, folderBounds.Y + folderBounds.H/2, folderBounds.Y + folderBounds.H - 1} {
			window.Move(x, y)
			if got != folder {
				t.Errorf("drop at (%v,%v) selected %v, want folder", x, y, got)
			}
		}
	}
	fileRect, ok := window.Find("file")
	if !ok {
		t.Fatal("missing file row")
	}
	window.Move(500, fileRect.Y+fileRect.H/2)
	if got != root {
		t.Fatal("file row must use the current directory")
	}
	window.Move(500, 380)
	if got != root {
		t.Fatal("blank space must use the current directory")
	}
}
