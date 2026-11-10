package platform

import (
	"errors"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// ProxyMode selects the operating system proxy or an application SOCKS5 proxy.
type ProxyMode string

const (
	ProxySystem ProxyMode = "system"
	ProxySOCKS5 ProxyMode = "socks5"
)

// ProxySettings contains the persisted proxy preferences. The password is stored separately.
type ProxySettings struct {
	Mode     ProxyMode `json:"mode"`
	Host     string    `json:"host"`
	Port     *int      `json:"port"`
	Username string    `json:"username"`
}

// Problem reports why a SOCKS5 draft cannot be applied.
func (s ProxySettings) Problem(password string) error {
	if s.Mode != ProxySOCKS5 {
		return nil
	}
	switch {
	case strings.TrimSpace(s.Host) == "":
		return errors.New("请填写代理服务器。")
	case s.Port == nil:
		return errors.New("请填写代理端口。")
	case *s.Port < 1 || *s.Port > 65535:
		return errors.New("端口需要在 1–65535 之间。")
	case (strings.TrimSpace(s.Username) == "") != (password == ""):
		return errors.New("用户名和密码需要同时填写。")
	default:
		return nil
	}
}

// NewTransport applies proxy settings to business requests. An incomplete SOCKS5
// draft leaves the system proxy active. The caller owns transport replacement.
func NewTransport(settings ProxySettings, password string) *http.Transport {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = systemProxy
	if settings.Mode == ProxySOCKS5 && settings.Problem(password) == nil {
		transport.Proxy = http.ProxyURL(socksProxy(settings.Host, *settings.Port, settings.Username, password))
	}
	return transport
}

func socksProxy(host string, port int, username, password string) *url.URL {
	proxy := &url.URL{
		Scheme: "socks5",
		Host:   net.JoinHostPort(strings.Trim(strings.TrimSpace(host), "[]"), strconv.Itoa(port)),
	}
	if username = strings.TrimSpace(username); username != "" {
		proxy.User = url.UserPassword(username, password)
	}
	return proxy
}

func proxyAddress(scheme, host string, port int) (*url.URL, error) {
	if host == "" || port < 0 || port > 65535 {
		return nil, errors.New("系统代理地址无效")
	}
	host = strings.Trim(host, "[]")
	if port != 0 {
		host = net.JoinHostPort(host, strconv.Itoa(port))
	} else if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	return &url.URL{Scheme: scheme, Host: host}, nil
}
