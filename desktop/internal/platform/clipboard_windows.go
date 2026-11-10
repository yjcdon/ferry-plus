package platform

import (
	"context"
	"errors"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/transfer"
)

var clipboardSequenceNumber = windowsSystemDLL("user32.dll").NewProc("GetClipboardSequenceNumber")

// CopiedShareText reports text only when its clipboard sequence stays stable.
func CopiedShareText(ctx context.Context, previous uint64, done func(text string, sequence uint64, changed bool)) {
	mygo.RunOnMain(func() {
		if ctx.Err() != nil || !mygo.App.IsActive() {
			done("", previous, false)
			return
		}
		before, _, _ := clipboardSequenceNumber.Call()
		sequence := uint64(uint32(before))
		if sequence == 0 || sequence == previous {
			done("", previous, false)
			return
		}
		text, err := mygo.Clipboard.ReadFormat(transfer.Text)
		after, _, _ := clipboardSequenceNumber.Call()
		if ctx.Err() != nil || !mygo.App.IsActive() || sequence != uint64(uint32(after)) || err != nil && !errors.Is(err, transfer.ErrFormat) {
			done("", previous, false)
			return
		}
		done(string(text), sequence, true)
	})
}
