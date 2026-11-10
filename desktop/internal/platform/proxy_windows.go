package platform

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"path"
	"strings"
	"syscall"
	"unicode"
	"unsafe"
)

const (
	winHTTPDirect           = 1
	winHTTPAutoDetect       = 1
	winHTTPAutoConfigURL    = 2
	winHTTPDetectDHCPAndDNS = 3
	winHTTPNoAutoProxy      = syscall.Errno(12180)
)

var (
	proxyKernel32      = syscall.NewLazyDLL("kernel32.dll") // Windows KnownDLL
	winHTTP            = windowsSystemDLL("winhttp.dll")
	winHTTPUserProxy   = winHTTP.NewProc("WinHttpGetIEProxyConfigForCurrentUser")
	winHTTPOpen        = winHTTP.NewProc("WinHttpOpen")
	winHTTPClose       = winHTTP.NewProc("WinHttpCloseHandle")
	winHTTPTimeouts    = winHTTP.NewProc("WinHttpSetTimeouts")
	winHTTPProxyForURL = winHTTP.NewProc("WinHttpGetProxyForUrl")
	winHTTPGlobalFree  = proxyKernel32.NewProc("GlobalFree")
)

// Load desktop API libraries from the system directory, even if a file with
// the same name is next to the executable.
func windowsSystemDLL(name string) *syscall.LazyDLL {
	var directory [syscall.MAX_PATH]uint16
	length, _, err := proxyKernel32.NewProc("GetSystemDirectoryW").Call(
		uintptr(unsafe.Pointer(&directory[0])), uintptr(len(directory)),
	)
	if length == 0 || length >= uintptr(len(directory)) {
		panic(fmt.Errorf("获取 Windows 系统目录: %w", err))
	}
	return syscall.NewLazyDLL(syscall.UTF16ToString(directory[:length]) + `\` + name)
}

type windowsUserProxyConfig struct {
	autoDetect uint32
	script     *uint16
	proxy      *uint16
	bypass     *uint16
}

type windowsAutoProxyOptions struct {
	flags         uint32
	detectFlags   uint32
	script        *uint16
	reserved      uintptr
	reservedFlags uint32
	autoLogon     uint32
}

type windowsProxyInfo struct {
	access uint32
	proxy  *uint16
	bypass *uint16
}

func systemProxy(request *http.Request) (*url.URL, error) {
	var config windowsUserProxyConfig
	if ok, _, err := winHTTPUserProxy.Call(uintptr(unsafe.Pointer(&config))); ok == 0 {
		if errors.Is(err, syscall.ERROR_FILE_NOT_FOUND) {
			return nil, nil
		}
		return nil, fmt.Errorf("读取 Windows 代理设置: %w", err)
	}
	defer freeProxyString(config.script)
	defer freeProxyString(config.proxy)
	defer freeProxyString(config.bypass)

	if config.autoDetect != 0 || config.script != nil {
		proxy, err := windowsAutoProxy(request.URL, config)
		// A network without WPAD may still have manual proxy settings.
		if !errors.Is(err, winHTTPNoAutoProxy) || config.script != nil {
			return proxy, err
		}
	}
	return windowsProxyURL(request.URL, windowsUTF16String(config.proxy), windowsUTF16String(config.bypass))
}

func windowsAutoProxy(target *url.URL, config windowsUserProxyConfig) (*url.URL, error) {
	session, _, err := winHTTPOpen.Call(0, winHTTPDirect, 0, 0, 0)
	if session == 0 {
		return nil, fmt.Errorf("创建 Windows 代理会话: %w", err)
	}
	defer winHTTPClose.Call(session)
	if ok, _, err := winHTTPTimeouts.Call(session, 5000, 5000, 5000, 5000); ok == 0 {
		return nil, fmt.Errorf("设置 Windows 代理会话超时: %w", err)
	}

	options := windowsAutoProxyOptions{script: config.script}
	if config.autoDetect != 0 {
		options.flags |= winHTTPAutoDetect
		options.detectFlags = winHTTPDetectDHCPAndDNS
	}
	if config.script != nil {
		options.flags |= winHTTPAutoConfigURL
	}
	rawURL, err := syscall.UTF16PtrFromString(target.String())
	if err != nil {
		return nil, fmt.Errorf("转换请求地址: %w", err)
	}
	var info windowsProxyInfo
	if ok, _, err := winHTTPProxyForURL.Call(session, uintptr(unsafe.Pointer(rawURL)),
		uintptr(unsafe.Pointer(&options)), uintptr(unsafe.Pointer(&info))); ok == 0 {
		return nil, fmt.Errorf("解析 Windows 自动代理: %w", err)
	}
	defer freeProxyString(info.proxy)
	defer freeProxyString(info.bypass)
	if info.access == winHTTPDirect {
		return nil, nil
	}
	return windowsProxyURL(target, windowsUTF16String(info.proxy), windowsUTF16String(info.bypass))
}

func freeProxyString(value *uint16) {
	if value != nil {
		winHTTPGlobalFree.Call(uintptr(unsafe.Pointer(value)))
	}
}

func windowsProxyURL(target *url.URL, servers, bypass string) (*url.URL, error) {
	host := strings.ToLower(target.Hostname())
	for _, pattern := range proxyFields(strings.ToLower(bypass)) {
		if pattern == "<local>" && !strings.Contains(host, ".") && net.ParseIP(host) == nil {
			return nil, nil
		}
		if match, _ := path.Match(pattern, host); match {
			return nil, nil
		}
	}

	var address, fallback, socks string
	for _, entry := range proxyFields(servers) {
		protocol, value, specific := strings.Cut(entry, "=")
		switch {
		case specific && strings.EqualFold(protocol, target.Scheme):
			address = value
		case specific && strings.EqualFold(protocol, "socks") && socks == "":
			socks = value
		case !specific && fallback == "":
			fallback = entry
		}
		if address != "" {
			break
		}
	}
	scheme := "http"
	if address == "" {
		address = fallback
	}
	if address == "" {
		address, scheme = socks, "socks5"
	}
	if address == "" {
		return nil, nil
	}
	if !strings.Contains(address, "://") {
		address = scheme + "://" + address
	}
	proxy, err := url.Parse(address)
	if err != nil || proxy.Hostname() == "" {
		return nil, fmt.Errorf("Windows 代理地址无效")
	}
	switch proxy.Scheme {
	case "http", "https", "socks5", "socks5h":
		return proxy, nil
	default:
		return nil, fmt.Errorf("Windows 代理协议无效")
	}
}

func proxyFields(value string) []string {
	return strings.FieldsFunc(value, func(r rune) bool {
		return r == ';' || unicode.IsSpace(r)
	})
}
