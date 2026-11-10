package platform

import (
	"errors"
	"fmt"
	"runtime"
	"unsafe"

	"github.com/ebitengine/purego/objc"
	"github.com/egoist/mygo"
)

const (
	bookmarkCreateScoped     = uint(1 << 11)
	bookmarkResolveScoped    = uint(1 << 10)
	bookmarkResolveWithoutUI = uint(1 << 8)
)

func chooseLocalItems(parent *mygo.Window, folderOnly bool, done func([]LocalReference, error)) func() {
	var panel objc.ID
	mygo.RunOnMain(func() {
		if parent == nil || parent.NativeHandle() == 0 {
			done(nil, errors.New("请重新打开文件选择窗口"))
			return
		}
		defer objcPool()()
		panel = objcSend[objc.ID](objcClass("NSOpenPanel"), "openPanel")
		objcSend[objc.ID](panel, "retain")
		objcSend[uintptr](panel, "setCanChooseFiles:", !folderOnly)
		objcSend[uintptr](panel, "setCanChooseDirectories:", true)
		objcSend[uintptr](panel, "setAllowsMultipleSelection:", !folderOnly)
		objcSend[uintptr](panel, "setCanCreateDirectories:", folderOnly)
		button := "上传"
		if folderOnly {
			button = "选择"
		}
		objcSend[uintptr](panel, "setPrompt:", objcString(button))

		handler := objc.NewBlock(func(_ objc.Block, response int) {
			defer objcPool()()
			selectedPanel := panel
			panel = 0
			defer objcSend[uintptr](selectedPanel, "release")
			if response != 1 { // NSModalResponseOK
				done(nil, nil)
				return
			}
			items := objcSend[objc.ID](selectedPanel, "URLs")
			count := objcSend[uint](items, "count")
			refs := make([]LocalReference, 0, count)
			for i := range count {
				url := objcSend[objc.ID](items, "objectAtIndex:", i)
				ref, err := rememberURL(url)
				if err != nil {
					done(nil, err)
					return
				}
				refs = append(refs, ref)
			}
			done(refs, nil)
		})
		defer handler.Release()
		objcSend[uintptr](panel, "beginSheetModalForWindow:completionHandler:", parent.NativeHandle(), handler)
	})
	return func() {
		mygo.RunOnMain(func() {
			if panel != 0 {
				objcSend[uintptr](panel, "cancel:", uintptr(0))
			}
		})
	}
}

func rememberLocalItem(path string) (LocalReference, error) {
	defer objcPool()()
	url := objcSend[objc.ID](objcClass("NSURL"), "fileURLWithPath:", objcString(path))
	return rememberURL(url)
}

func rememberURL(url objc.ID) (LocalReference, error) {
	if !objcSend[bool](url, "isFileURL") {
		return LocalReference{}, errors.New("请选择本地文件或文件夹")
	}
	path := goString(objcSend[objc.ID](url, "path"))
	if objcSend[bool](url, "startAccessingSecurityScopedResource") {
		defer objcSend[uintptr](url, "stopAccessingSecurityScopedResource")
	}
	bookmark, err := bookmarkForURL(url)
	if err != nil {
		return LocalReference{}, fmt.Errorf("保存文件访问权限 %q: %w", path, err)
	}
	return LocalReference{Path: path, Bookmark: bookmark}, nil
}

func openLocalItem(ref LocalReference) (*LocalAccess, error) {
	if len(ref.Bookmark) == 0 {
		return &LocalAccess{Reference: ref}, nil
	}
	defer objcPool()()
	bytes := objcSend[objc.ID](objcClass("NSData"), "dataWithBytes:length:",
		unsafe.Pointer(unsafe.SliceData(ref.Bookmark)), uint(len(ref.Bookmark)))
	runtime.KeepAlive(ref.Bookmark)

	var stale bool
	var failure objc.ID
	url := objcSend[objc.ID](objcClass("NSURL"), "URLByResolvingBookmarkData:options:relativeToURL:bookmarkDataIsStale:error:",
		bytes, bookmarkResolveScoped|bookmarkResolveWithoutUI, objc.ID(0), &stale, &failure)
	if url == 0 {
		return nil, fmt.Errorf("恢复文件访问权限 %q: %w", ref.Path, objcError(failure))
	}
	if !objcSend[bool](url, "startAccessingSecurityScopedResource") {
		return nil, fmt.Errorf("恢复文件访问权限 %q: %w", ref.Path, errors.New("系统未授予访问权限"))
	}
	objcSend[objc.ID](url, "retain")
	ref.Path = goString(objcSend[objc.ID](url, "path"))
	access := &LocalAccess{Reference: ref, release: func() {
		defer objcPool()()
		objcSend[uintptr](url, "stopAccessingSecurityScopedResource")
		objcSend[uintptr](url, "release")
	}}
	if stale {
		bookmark, err := bookmarkForURL(url)
		if err != nil {
			access.Close()
			return nil, fmt.Errorf("更新文件访问权限 %q: %w", ref.Path, err)
		}
		access.Reference.Bookmark = bookmark
	}
	return access, nil
}

func bookmarkForURL(url objc.ID) ([]byte, error) {
	var failure objc.ID
	data := objcSend[objc.ID](url, "bookmarkDataWithOptions:includingResourceValuesForKeys:relativeToURL:error:",
		bookmarkCreateScoped, objc.ID(0), objc.ID(0), &failure)
	if data == 0 {
		return nil, objcError(failure)
	}
	size := objcSend[int](data, "length")
	bytes := objcSend[*byte](data, "bytes")
	return append([]byte(nil), unsafe.Slice(bytes, size)...), nil
}

func objcPool() func() {
	runtime.LockOSThread()
	pool := objcSend[objc.ID](objcClass("NSAutoreleasePool"), "new")
	return func() {
		objcSend[uintptr](pool, "drain")
		runtime.UnlockOSThread()
	}
}

func objcClass(name string) objc.ID { return objc.ID(objc.GetClass(name)) }

func objcSend[T any](receiver objc.ID, selector string, args ...any) T {
	return objc.Send[T](receiver, objc.RegisterName(selector), args...)
}

func objcString(s string) objc.ID {
	value := objcSend[objc.ID](objcClass("NSString"), "alloc")
	value = objcSend[objc.ID](value, "initWithBytes:length:encoding:",
		unsafe.Pointer(unsafe.StringData(s)), uint(len(s)), uint(4)) // NSUTF8StringEncoding
	runtime.KeepAlive(s)
	return objcSend[objc.ID](value, "autorelease")
}

func goString(value objc.ID) string {
	bytes := objcSend[*byte](value, "UTF8String")
	size := objcSend[int](value, "lengthOfBytesUsingEncoding:", uint(4))
	return string(unsafe.Slice(bytes, size))
}

func objcError(value objc.ID) error {
	message := goString(objcSend[objc.ID](value, "localizedDescription"))
	if message == "" {
		return errors.New("系统未返回错误详情")
	}
	return errors.New(message)
}

func validateLocalNames(string) error { return nil }
