package platform

import (
	"context"
	"strconv"
	"strings"
	"sync"
	"syscall"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"
	"github.com/egoist/mygo"
)

// CopiedShareText reports a new stable clipboard version on the main thread.
// On macOS 15.4 and later AppKit detects a probable URL before reading text.
func CopiedShareText(ctx context.Context, previous uint64, done func(text string, sequence uint64, changed bool)) {
	mygo.RunOnMain(func() {
		defer objcPool()()
		if ctx.Err() != nil || !mygo.App.IsActive() {
			done("", previous, false)
			return
		}
		board := objcSend[objc.ID](objcClass("NSPasteboard"), "generalPasteboard")
		sequence := pasteboardSequence(board)
		if board == 0 || sequence == previous {
			done("", previous, false)
			return
		}
		read := func(matches bool) {
			if ctx.Err() != nil || !mygo.App.IsActive() || pasteboardSequence(board) != sequence {
				done("", previous, false)
				return
			}
			var text string
			if matches {
				text = goString(objcSend[objc.ID](board, "stringForType:", objcString("public.utf8-plain-text")))
			}
			if ctx.Err() != nil || !mygo.App.IsActive() || pasteboardSequence(board) != sequence {
				done("", previous, false)
				return
			}
			done(text, sequence, true)
		}
		if legacyPasteboardAccess() {
			read(true)
			return
		}

		pattern := probableWebURLPattern()
		const detect = "detectPatternsForPatterns:completionHandler:"
		if pattern == 0 || !objcSend[bool](board, "respondsToSelector:", objc.RegisterName(detect)) ||
			!pasteboardAccessAllowed(board) {
			read(false)
			return
		}
		patterns := objcSend[objc.ID](objcClass("NSSet"), "setWithObject:", pattern)
		completed := objc.NewBlock(func(_ objc.Block, matched, failure objc.ID) {
			matches := failure == 0 && objcSend[bool](matched, "containsObject:", pattern)
			mygo.RunOnMain(func() {
				defer objcPool()()
				read(matches && pasteboardAccessAllowed(board))
			})
		})
		defer completed.Release()
		objcSend[uintptr](board, detect, patterns, completed)
	})
}

func pasteboardSequence(board objc.ID) uint64 {
	return uint64(objcSend[int](board, "changeCount"))
}

func pasteboardAccessAllowed(board objc.ID) bool {
	const access = "accessBehavior"
	if !objcSend[bool](board, "respondsToSelector:", objc.RegisterName(access)) {
		return false
	}
	switch objcSend[int](board, access) {
	case 0, 1, 2: // default, ask, always allow
		return true
	default:
		return false
	}
}

// Older systems have no automatic clipboard privacy prompt. An unknown version
// takes the modern, metadata-first path.
var legacyPasteboardAccess = sync.OnceValue(func() bool {
	version, err := syscall.Sysctl("kern.osproductversion")
	if err != nil {
		return false
	}
	majorText, rest, _ := strings.Cut(version, ".")
	minorText, _, _ := strings.Cut(rest, ".")
	major, majorErr := strconv.Atoi(majorText)
	minor, minorErr := strconv.Atoi(minorText)
	return majorErr == nil && minorErr == nil && (major < 15 || major == 15 && minor < 4)
})

// The exported AppKit constant is the address of an NSString pointer.
var probableWebURLPattern = sync.OnceValue(func() objc.ID {
	dlsym, err := purego.Dlsym(purego.RTLD_DEFAULT, "dlsym")
	if err != nil {
		return 0
	}
	var lookup func(uintptr, string) *objc.ID
	purego.RegisterFunc(&lookup, dlsym)
	symbol := lookup(purego.RTLD_DEFAULT, "NSPasteboardDetectionPatternProbableWebURL")
	if symbol == nil {
		return 0
	}
	return *symbol
})
