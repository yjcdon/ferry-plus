package ui

import (
	"github.com/egoist/mygo/ui"

	"github.com/yjcdon/ferry-drive/desktop/internal/app"
)

type directoryDropRow struct {
	ref    app.RemoteRef
	bounds ui.Rect
}

// directoryTableDropTarget treats every column and the trailing space of a folder row
// as that folder. Files, the header and empty table space use the current directory.
func directoryTableDropTarget(c *ui.Context, table ui.Element, rows []directoryDropRow, root app.RemoteRef) app.RemoteRef {
	// Native drag events provide coordinates without setting the ordinary pointer-over flag.
	// DropData on the table already establishes that the actual drop hit this table.
	_, y, _ := table.PointerPosition()
	if y < c.Theme().Space(8)+1 {
		return root
	}
	y += table.Bounds().Y
	for _, row := range rows {
		if row.bounds.W > 0 && y >= row.bounds.Y && y < row.bounds.Y+row.bounds.H {
			return row.ref
		}
	}
	return root
}

// directoryDropRowBounds includes MyGo's cell padding and minimum row height around the name content.
func directoryDropRowBounds(c *ui.Context, content ui.Element) ui.Rect {
	bounds := content.Bounds()
	height := max(c.Theme().Space(8), bounds.H+c.Theme().Space(3))
	bounds.Y -= (height - bounds.H) / 2
	bounds.H = height
	return bounds
}
