package platform

import (
	"fmt"
	"runtime"
	"sync"
	"syscall"
	"unsafe"

	"github.com/egoist/mygo"
)

const (
	dialogCanceled = 0x800704c7 // HRESULT_FROM_WIN32(ERROR_CANCELLED)
	mixedSelectID  = 100

	fileDialogShow             = 3
	fileDialogAdvise           = 7
	fileDialogUnadvise         = 8
	fileDialogSetOptions       = 9
	fileDialogGetOptions       = 10
	fileDialogSetButtonLabel   = 18
	fileDialogClose            = 23
	fileOpenGetResults         = 27
	fileOpenGetSelectedItems   = 28
	fileDialogAddPushButton    = 5
	shellItemGetDisplayName    = 5
	shellItemArrayGetCount     = 7
	shellItemArrayGetItem      = 8
	fileDialogPickFolders      = 0x20
	fileDialogForceFileSystem  = 0x40
	fileDialogAllowMultiselect = 0x200
	shellItemFileSystemPath    = 0x80058000
)

var (
	pickerOle32        = windowsSystemDLL("ole32.dll")
	pickerCreate       = pickerOle32.NewProc("CoCreateInstance")
	pickerFree         = pickerOle32.NewProc("CoTaskMemFree")
	classFileOpen      = syscall.GUID{Data1: 0xdc1c5a9c, Data2: 0xe88a, Data3: 0x4dde, Data4: [8]byte{0xa5, 0xa1, 0x60, 0xf8, 0x2a, 0x20, 0xae, 0xf7}}
	iidFileOpen        = syscall.GUID{Data1: 0xd57c7288, Data2: 0xd4ad, Data3: 0x4768, Data4: [8]byte{0xbe, 0x02, 0x9d, 0x96, 0x95, 0x32, 0xd9, 0x60}}
	iidDialogCustomize = syscall.GUID{Data1: 0xe6fdd21a, Data2: 0x163f, Data3: 0x4975, Data4: [8]byte{0x9c, 0x8c, 0xa6, 0x9f, 0x1b, 0xa3, 0x70, 0x34}}
	iidDialogEvents    = syscall.GUID{Data1: 0x973510db, Data2: 0x7d7f, Data3: 0x452b, Data4: [8]byte{0x89, 0x75, 0x74, 0xa8, 0x58, 0x28, 0xd3, 0x54}}
	iidControlEvents   = syscall.GUID{Data1: 0x36116642, Data2: 0xd713, Data3: 0x4b97, Data4: [8]byte{0x9b, 0x83, 0x74, 0x84, 0xa9, 0xd0, 0x04, 0x33}}
	iidUnknown         = syscall.GUID{Data4: [8]byte{0xc0, 0, 0, 0, 0, 0, 0, 0x46}}
)

type pickerResult struct {
	paths []LocalReference
	err   error
}

func chooseLocalItems(parent *mygo.Window, mode localPickerMode, done func([]LocalReference, error)) func() {
	var dialog uintptr
	var canceled bool
	go mygo.RunOnMain(func() {
		if canceled {
			done(nil, nil)
			return
		}
		if parent == nil || parent.NativeHandle() == 0 {
			done(nil, fmt.Errorf("请重新打开文件选择窗口"))
			return
		}
		paths, err := showLocalDialog(parent.NativeHandle(), mode, &dialog)
		done(paths, err)
	})
	return func() {
		mygo.RunOnMain(func() {
			canceled = true
			if dialog != 0 {
				pickerCall(dialog, fileDialogClose, dialogCanceled)
			}
		})
	}
}

func showLocalDialog(owner uintptr, mode localPickerMode, dialog *uintptr) ([]LocalReference, error) {
	hr, _, _ := pickerCreate.Call(uintptr(unsafe.Pointer(&classFileOpen)), 0, 1,
		uintptr(unsafe.Pointer(&iidFileOpen)), uintptr(unsafe.Pointer(dialog)))
	if err := pickerError("打开文件选择器", hr); err != nil {
		return nil, err
	}
	defer func() {
		pickerCall(*dialog, 2)
		*dialog = 0
	}()

	var options uint32
	if err := pickerError("读取文件选择器选项", pickerCall(*dialog, fileDialogGetOptions, uintptr(unsafe.Pointer(&options)))); err != nil {
		return nil, err
	}
	options |= fileDialogForceFileSystem
	if mode == pickDownloadFolder {
		options |= fileDialogPickFolders
	}
	if mode != pickUploadItems {
		label, _ := syscall.UTF16PtrFromString("选择")
		if err := pickerError("设置选择按钮", pickerCall(*dialog, fileDialogSetButtonLabel, uintptr(unsafe.Pointer(label)))); err != nil {
			return nil, err
		}
	} else {
		options |= fileDialogAllowMultiselect
	}
	if err := pickerError("设置文件选择器选项", pickerCall(*dialog, fileDialogSetOptions, uintptr(options))); err != nil {
		return nil, err
	}

	var selection pickerResult
	if mode == pickUploadItems {
		remove, err := addMixedSelection(*dialog, &selection)
		if err != nil {
			return nil, err
		}
		defer remove()
	}
	switch hr := pickerCall(*dialog, fileDialogShow, owner); {
	case uint32(hr) == dialogCanceled:
		return nil, nil
	case int32(hr) < 0:
		return nil, pickerError("显示文件选择器", hr)
	case len(selection.paths) != 0 || selection.err != nil:
		return selection.paths, selection.err
	default:
		return dialogItems(*dialog, fileOpenGetResults)
	}
}

func dialogItems(dialog uintptr, method int) ([]LocalReference, error) {
	var array uintptr
	if err := pickerError("取得选中项目", pickerCall(dialog, method, uintptr(unsafe.Pointer(&array)))); err != nil {
		return nil, err
	}
	defer pickerCall(array, 2)

	var count uint32
	if err := pickerError("读取选中项目数量", pickerCall(array, shellItemArrayGetCount, uintptr(unsafe.Pointer(&count)))); err != nil {
		return nil, err
	}
	items := make([]LocalReference, 0, count)
	for i := range count {
		var item uintptr
		if err := pickerError("读取选中项目", pickerCall(array, shellItemArrayGetItem, uintptr(i), uintptr(unsafe.Pointer(&item)))); err != nil {
			return nil, err
		}
		var path *uint16
		hr := pickerCall(item, shellItemGetDisplayName, shellItemFileSystemPath, uintptr(unsafe.Pointer(&path)))
		pickerCall(item, 2)
		if err := pickerError("读取项目本地路径", hr); err != nil {
			return nil, err
		}
		items = append(items, LocalReference{Path: windowsUTF16String(path)})
		pickerFree.Call(uintptr(unsafe.Pointer(path)))
	}
	return items, nil
}

func pickerCall(object uintptr, method int, args ...uintptr) uintptr {
	table := *(**[32]uintptr)(pickerPointer(object))
	result, _, _ := syscall.SyscallN(table[method], append([]uintptr{object}, args...)...)
	return result
}

func pickerError(operation string, result uintptr) error {
	if int32(result) < 0 {
		return fmt.Errorf("%s (HRESULT 0x%08x)", operation, uint32(result))
	}
	return nil
}

// IFileDialog's default Open action navigates into folders. The extra action
// reads the highlighted items as-is, including folders in a mixed selection.
func addMixedSelection(dialog uintptr, selection *pickerResult) (func(), error) {
	var customize uintptr
	hr := pickerCall(dialog, 0, uintptr(unsafe.Pointer(&iidDialogCustomize)), uintptr(unsafe.Pointer(&customize)))
	if err := pickerError("自定义文件选择器", hr); err != nil {
		return nil, err
	}
	defer pickerCall(customize, 2)
	label, _ := syscall.UTF16PtrFromString("上传所选项目")
	hr = pickerCall(customize, fileDialogAddPushButton, mixedSelectID, uintptr(unsafe.Pointer(label)))
	if err := pickerError("添加混合选择按钮", hr); err != nil {
		return nil, err
	}

	sink := &pickerEventSink{dialog: dialog, refs: 1}
	sink.events, sink.controls = eventTables()
	var pin runtime.Pinner
	pin.Pin(sink)
	address := uintptr(unsafe.Pointer(sink))
	activePickers[address] = selection

	var cookie uint32
	hr = pickerCall(dialog, fileDialogAdvise, address, uintptr(unsafe.Pointer(&cookie)))
	clean := func() {
		delete(activePickers, address)
		pin.Unpin()
	}
	if err := pickerError("监听文件选择", hr); err != nil {
		clean()
		return nil, err
	}
	return func() {
		pickerCall(dialog, fileDialogUnadvise, uintptr(cookie))
		clean()
	}, nil
}

// Both COM interfaces share a single reference count and IUnknown identity.
type pickerEventSink struct {
	events   uintptr
	controls uintptr
	dialog   uintptr
	refs     uintptr
}

var activePickers = map[uintptr]*pickerResult{} // Windows UI thread only.

var pickerEventTable [10]uintptr
var pickerControlTable [7]uintptr
var initPickerTables = sync.OnceFunc(func() {
	callback := syscall.NewCallback
	ok2 := callback(func(uintptr, uintptr) uintptr { return 0 })
	ok3 := callback(func(uintptr, uintptr, uintptr) uintptr { return 0 })
	defaultResponse := callback(func(_, _, _, response uintptr) uintptr {
		*(*uint32)(pickerPointer(response)) = 0
		return 0
	})
	query := func(address, iid, out uintptr) uintptr {
		*(*uintptr)(pickerPointer(out)) = 0
		switch *(*syscall.GUID)(pickerPointer(iid)) {
		case iidUnknown, iidDialogEvents:
			*(*uintptr)(pickerPointer(out)) = address
		case iidControlEvents:
			*(*uintptr)(pickerPointer(out)) = address + unsafe.Offsetof(pickerEventSink{}.controls)
		default:
			return 0x80004002 // E_NOINTERFACE
		}
		(*pickerEventSink)(pickerPointer(address)).refs++
		return 0
	}
	add := func(address uintptr) uintptr {
		sink := (*pickerEventSink)(pickerPointer(address))
		sink.refs++
		return sink.refs
	}
	release := func(address uintptr) uintptr {
		sink := (*pickerEventSink)(pickerPointer(address))
		sink.refs--
		return sink.refs
	}
	pickerEventTable = [10]uintptr{
		callback(query), callback(add), callback(release),
		ok2, ok3, ok2, ok2, defaultResponse, ok2, defaultResponse,
	}
	pickerControlTable = [7]uintptr{
		callback(func(this, iid, out uintptr) uintptr { return query(pickerOwner(this), iid, out) }),
		callback(func(this uintptr) uintptr { return add(pickerOwner(this)) }),
		callback(func(this uintptr) uintptr { return release(pickerOwner(this)) }),
		callback(func(uintptr, uintptr, uintptr, uintptr) uintptr { return 0 }), // OnItemSelected
		callback(func(this, _, control uintptr) uintptr {
			if control != mixedSelectID {
				return 0
			}
			address := pickerOwner(this)
			dialog := (*pickerEventSink)(pickerPointer(address)).dialog
			selection := activePickers[address]
			paths, err := dialogItems(dialog, fileOpenGetSelectedItems)
			if len(paths) == 0 && err == nil {
				return 0
			}
			selection.paths, selection.err = paths, err
			return pickerCall(dialog, fileDialogClose, 0)
		}),
		callback(func(uintptr, uintptr, uintptr, uintptr) uintptr { return 0 }), // OnCheckButtonToggled
		ok3, // OnControlActivating
	}
})

func eventTables() (uintptr, uintptr) {
	initPickerTables()
	return uintptr(unsafe.Pointer(&pickerEventTable)), uintptr(unsafe.Pointer(&pickerControlTable))
}

func pickerOwner(control uintptr) uintptr {
	return control - unsafe.Offsetof(pickerEventSink{}.controls)
}

func pickerPointer(address uintptr) unsafe.Pointer {
	return *(*unsafe.Pointer)(unsafe.Pointer(&address))
}

func windowsUTF16String(value *uint16) string {
	if value == nil {
		return ""
	}
	units := 0
	for *(*uint16)(unsafe.Add(unsafe.Pointer(value), units*2)) != 0 {
		units++
	}
	return syscall.UTF16ToString(unsafe.Slice(value, units))
}
