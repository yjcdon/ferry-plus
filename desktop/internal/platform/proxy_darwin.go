package platform

import (
	"bytes"
	"fmt"
	"net/http"
	"net/url"
	"runtime"
	"sync"
	"sync/atomic"
	"unsafe"

	"github.com/ebitengine/purego"
)

const cfUTF8 = 0x08000100

var appleProxy = sync.OnceValue(loadAppleProxy)

type appleProxyAPI struct {
	systemSettings func() uintptr
	proxiesForURL  func(uintptr, uintptr) uintptr
	pacURL         func(uintptr, uintptr, uintptr, *proxyStreamContext) uintptr
	pacScript      func(uintptr, uintptr, uintptr, *proxyStreamContext) uintptr
	callback       uintptr

	createURL     func(uintptr, *byte, int, uint32, uintptr) uintptr
	release       func(uintptr)
	retain        func(uintptr) uintptr
	equal         func(uintptr, uintptr) bool
	arrayCount    func(uintptr) int
	arrayValue    func(uintptr, int) uintptr
	dictValue     func(uintptr, uintptr) uintptr
	stringLength  func(uintptr) int
	stringMaxSize func(int, uint32) int
	stringCString func(uintptr, *byte, int, uint32) bool
	numberValue   func(uintptr, int, *int32) bool
	errorCode     func(uintptr) int
	runLoop       func() uintptr
	addSource     func(uintptr, uintptr, uintptr)
	removeSource  func(uintptr, uintptr, uintptr)
	invalidate    func(uintptr)
	runMode       func(uintptr, float64, bool) int32
	stop          func(uintptr)
	defaultMode   uintptr

	typeKey, hostKey, portKey, userKey, passwordKey uintptr
	pacURLKey, pacScriptKey                         uintptr
	none, http, https, socks, autoURL, autoScript   uintptr
}

func loadAppleProxy() *appleProxyAPI {
	cf, err := purego.Dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", purego.RTLD_LAZY|purego.RTLD_LOCAL)
	if err != nil {
		panic(err)
	}
	network, err := purego.Dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", purego.RTLD_LAZY|purego.RTLD_LOCAL)
	if err != nil {
		panic(err)
	}
	p := new(appleProxyAPI)
	purego.RegisterLibFunc(&p.systemSettings, network, "CFNetworkCopySystemProxySettings")
	purego.RegisterLibFunc(&p.proxiesForURL, network, "CFNetworkCopyProxiesForURL")
	purego.RegisterLibFunc(&p.pacURL, network, "CFNetworkExecuteProxyAutoConfigurationURL")
	purego.RegisterLibFunc(&p.pacScript, network, "CFNetworkExecuteProxyAutoConfigurationScript")
	purego.RegisterLibFunc(&p.createURL, cf, "CFURLCreateWithBytes")
	purego.RegisterLibFunc(&p.release, cf, "CFRelease")
	purego.RegisterLibFunc(&p.retain, cf, "CFRetain")
	purego.RegisterLibFunc(&p.equal, cf, "CFEqual")
	purego.RegisterLibFunc(&p.arrayCount, cf, "CFArrayGetCount")
	purego.RegisterLibFunc(&p.arrayValue, cf, "CFArrayGetValueAtIndex")
	purego.RegisterLibFunc(&p.dictValue, cf, "CFDictionaryGetValue")
	purego.RegisterLibFunc(&p.stringLength, cf, "CFStringGetLength")
	purego.RegisterLibFunc(&p.stringMaxSize, cf, "CFStringGetMaximumSizeForEncoding")
	purego.RegisterLibFunc(&p.stringCString, cf, "CFStringGetCString")
	purego.RegisterLibFunc(&p.numberValue, cf, "CFNumberGetValue")
	purego.RegisterLibFunc(&p.errorCode, cf, "CFErrorGetCode")
	purego.RegisterLibFunc(&p.runLoop, cf, "CFRunLoopGetCurrent")
	purego.RegisterLibFunc(&p.addSource, cf, "CFRunLoopAddSource")
	purego.RegisterLibFunc(&p.removeSource, cf, "CFRunLoopRemoveSource")
	purego.RegisterLibFunc(&p.invalidate, cf, "CFRunLoopSourceInvalidate")
	purego.RegisterLibFunc(&p.runMode, cf, "CFRunLoopRunInMode")
	purego.RegisterLibFunc(&p.stop, cf, "CFRunLoopStop")
	readConstant := func(library uintptr, name string) uintptr {
		address, err := purego.Dlsym(library, name)
		if err != nil {
			panic(err)
		}
		return **(**uintptr)(unsafe.Pointer(&address))
	}
	p.defaultMode = readConstant(cf, "kCFRunLoopDefaultMode")
	p.typeKey = readConstant(network, "kCFProxyTypeKey")
	p.hostKey = readConstant(network, "kCFProxyHostNameKey")
	p.portKey = readConstant(network, "kCFProxyPortNumberKey")
	p.userKey = readConstant(network, "kCFProxyUsernameKey")
	p.passwordKey = readConstant(network, "kCFProxyPasswordKey")
	p.pacURLKey = readConstant(network, "kCFProxyAutoConfigurationURLKey")
	p.pacScriptKey = readConstant(network, "kCFProxyAutoConfigurationJavaScriptKey")
	p.none = readConstant(network, "kCFProxyTypeNone")
	p.http = readConstant(network, "kCFProxyTypeHTTP")
	p.https = readConstant(network, "kCFProxyTypeHTTPS")
	p.socks = readConstant(network, "kCFProxyTypeSOCKS")
	p.autoURL = readConstant(network, "kCFProxyTypeAutoConfigurationURL")
	p.autoScript = readConstant(network, "kCFProxyTypeAutoConfigurationJavaScript")
	p.callback = purego.NewCallback(p.pacResult)
	return p
}

func systemProxy(request *http.Request) (*url.URL, error) {
	p := appleProxy()
	raw := []byte(request.URL.String())
	target := p.createURL(0, &raw[0], len(raw), cfUTF8, 0)
	if target == 0 {
		return nil, fmt.Errorf("无法解析请求地址的系统代理")
	}
	defer p.release(target)

	settings := p.systemSettings()
	if settings == 0 {
		// CFNetwork uses NULL when no system proxy settings exist.
		return nil, nil
	}
	defer p.release(settings)
	entries := p.proxiesForURL(target, settings)
	if entries == 0 {
		return nil, fmt.Errorf("无法读取请求的系统代理")
	}
	defer p.release(entries)
	return p.firstProxy(entries, target)
}

func (p *appleProxyAPI) firstProxy(entries, target uintptr) (*url.URL, error) {
	for i, count := 0, p.arrayCount(entries); i < count; i++ {
		entry := p.arrayValue(entries, i)
		kind := p.dictValue(entry, p.typeKey)
		if kind == 0 {
			continue
		}
		switch {
		case p.equal(kind, p.none):
			return nil, nil
		case p.equal(kind, p.http), p.equal(kind, p.https):
			// HTTPS here selects origin URLs. The proxy itself accepts HTTP CONNECT.
			return p.proxyURL(entry, "http")
		case p.equal(kind, p.socks):
			return p.proxyURL(entry, "socks5")
		case p.equal(kind, p.autoURL), p.equal(kind, p.autoScript):
			if target == 0 {
				break
			}
			execute, key := p.pacURL, p.pacURLKey
			if p.equal(kind, p.autoScript) {
				execute, key = p.pacScript, p.pacScriptKey
			}
			proxies, err := p.evaluatePAC(execute, p.dictValue(entry, key), target)
			if err != nil {
				return nil, err
			}
			defer p.release(proxies)
			return p.firstProxy(proxies, 0)
		}
	}
	return nil, fmt.Errorf("系统代理没有可用的 HTTP 或 SOCKS5 线路")
}

func (p *appleProxyAPI) proxyURL(entry uintptr, scheme string) (*url.URL, error) {
	host := p.goString(p.dictValue(entry, p.hostKey))
	var port int32
	if value := p.dictValue(entry, p.portKey); value != 0 {
		p.numberValue(value, 3, &port) // kCFNumberSInt32Type
	}
	proxy, err := proxyAddress(scheme, host, int(port))
	if err == nil {
		if user := p.goString(p.dictValue(entry, p.userKey)); user != "" {
			proxy.User = url.UserPassword(user, p.goString(p.dictValue(entry, p.passwordKey)))
		}
	}
	return proxy, err
}

func (p *appleProxyAPI) goString(value uintptr) string {
	if value == 0 {
		return ""
	}
	buffer := make([]byte, p.stringMaxSize(p.stringLength(value), cfUTF8)+1)
	if !p.stringCString(value, &buffer[0], len(buffer), cfUTF8) {
		return ""
	}
	return string(bytes.TrimRight(buffer, "\x00"))
}

// A CFStreamClientContext contains version, info, and three optional callbacks.
type proxyStreamContext struct {
	version, info, retain, release, description uintptr
}

type applePACResult struct {
	loop, proxies uintptr
	code          int
}

var (
	pacID      atomic.Uintptr
	pacResults sync.Map
)

func (p *appleProxyAPI) pacResult(id, proxies, failure uintptr) {
	if state, ok := pacResults.Load(id); ok {
		result := state.(*applePACResult)
		if proxies != 0 {
			result.proxies = p.retain(proxies)
		}
		if failure != 0 {
			result.code = p.errorCode(failure)
		}
		p.stop(result.loop)
	}
}

func (p *appleProxyAPI) evaluatePAC(execute func(uintptr, uintptr, uintptr, *proxyStreamContext) uintptr, script, target uintptr) (uintptr, error) {
	if script == 0 {
		return 0, fmt.Errorf("系统代理缺少自动配置脚本")
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	result := &applePACResult{loop: p.runLoop()}
	id := pacID.Add(1)
	pacResults.Store(id, result)
	defer pacResults.Delete(id)
	source := execute(script, target, p.callback, &proxyStreamContext{info: id})
	if source == 0 {
		return 0, fmt.Errorf("无法启动系统代理自动配置")
	}
	defer p.release(source)
	p.addSource(result.loop, source, p.defaultMode)
	p.runMode(p.defaultMode, 10, false)
	p.removeSource(result.loop, source, p.defaultMode)
	p.invalidate(source)
	if result.proxies == 0 {
		if result.code != 0 {
			return 0, fmt.Errorf("系统代理自动配置失败（%d）", result.code)
		}
		return 0, fmt.Errorf("系统代理自动配置未返回结果")
	}
	return result.proxies, nil
}
