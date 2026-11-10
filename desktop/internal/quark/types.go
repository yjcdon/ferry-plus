// Package quark implements the existing Quark web and drive protocols.
package quark

import (
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// RootFID is Quark's virtual root directory identifier.
const RootFID = "0"

var (
	// ErrDirectoryCreationRejected means the server explicitly refused mkdir.
	ErrDirectoryCreationRejected = errors.New("夸克未创建目录。")
	ErrInvalidResponse           = errors.New("夸克服务响应异常，请稍后重试。")
	ErrLoginExpired              = errors.New("夸克登录已失效，请在官方页面重新登录。")
	ErrAccountChanged            = errors.New("返回的夸克账号与已保存账号不同，请重新登录。")
	ErrMissingIdentity           = errors.New("登录确认失败，请重新登录。")
	ErrMissingCredential         = errors.New("请重新登录夸克网盘。")
	ErrUnsafeRedirect            = errors.New("登录地址异常，请重新登录。")
	ErrInvalidShareLink          = errors.New("请输入有效的夸克网盘分享链接。")
	ErrInvalidSelection          = errors.New("夸克文件选择或目录身份无效，请重新打开文件列表。")
	ErrShareRequiresCode         = errors.New("这个夸克分享需要提取码，请填写后重试。")
	ErrInvalidPasscode           = errors.New("夸克分享提取码不正确，请检查后重试。")
	ErrShareUnavailable          = errors.New("请检查分享链接并重新打开。")
)

// ServiceError retains the service code and its original diagnostic message.
type ServiceError struct {
	Code    string
	Message string
}

var servicePlaceholder = regexp.MustCompile(`\{\d+\}`)

func (e *ServiceError) Error() string {
	if e.Code == "32003" {
		return "夸克网盘空间不足（业务码 32003）。请在夸克官方页面检查可用空间和空间权益，处理后再重试。"
	}
	if e.Message == "" {
		return fmt.Sprintf("夸克请求未成功（业务码 %s），请稍后重试。", e.Code)
	}
	return fmt.Sprintf("夸克请求未成功：%s（业务码 %s）。", servicePlaceholder.ReplaceAllString(e.Message, "参数未提供"), e.Code)
}

// HTTPError identifies a rejected transport response.
type HTTPError int

func (e HTTPError) Error() string {
	switch e {
	case 403:
		return "夸克拒绝访问（HTTP 403），请在夸克官方页面确认该文件和账号的访问权限。"
	case 404:
		return "夸克请求的资源不存在（HTTP 404），请在夸克官方页面确认文件或分享是否仍然可用。"
	case 429:
		return "夸克请求过于频繁（HTTP 429），请降低并发数，稍后重试。"
	default:
		return fmt.Sprintf("夸克请求失败（HTTP %d），请稍后重试。", e)
	}
}

type Account struct {
	ID       string
	Nickname string
}

// Cookie records whether a cookie applies to one host or a domain and its subdomains.
// A leading dot in Domain indicates the latter, as in the platform login session.
type Cookie struct {
	Name    string     `json:"name"`
	Value   string     `json:"value"`
	Domain  string     `json:"domain"`
	Path    string     `json:"path"`
	Expires *time.Time `json:"expires,omitempty"`
	Secure  bool       `json:"secure"`
}

// Credential belongs in encrypted storage.
type Credential struct {
	Cookies []Cookie `json:"cookies"`
}

func (c Cookie) current(now time.Time) bool { return c.Expires == nil || c.Expires.After(now) }

func quarkDomain(domain string) bool {
	return domain == "quark.cn" || strings.HasSuffix(domain, ".quark.cn")
}

// CredentialFromWebCookies extracts a candidate login from the isolated official page.
func CredentialFromWebCookies(webCookies []Cookie) (Credential, error) {
	var credential Credential
	names := make(map[string]bool)
	now := time.Now()
	for _, cookie := range webCookies {
		cookie.Domain = strings.ToLower(cookie.Domain)
		if !quarkDomain(strings.TrimPrefix(cookie.Domain, ".")) || !cookie.current(now) {
			continue
		}
		if cookie.Path == "" {
			cookie.Path = "/"
		}
		credential.Cookies = append(credential.Cookies, cookie)
		if cookie.Value != "" {
			names[cookie.Name] = true
		}
	}
	if !names["__pus"] || !names["__kps"] || !names["__uid"] {
		return Credential{}, ErrMissingCredential
	}
	return credential, nil
}

// Login represents a confirmed identity with drive access.
type Login struct {
	Account    Account
	Credential Credential
	VerifiedAt time.Time
}

type Capacity struct {
	Total int64
	Used  int64
}

type Entry struct {
	FID           string
	Name          string
	IsDirectory   bool
	Size          int64
	UpdatedAt     *time.Time
	MD5           string
	ShareFIDToken string
	ParentFID     string
}

type ShareLink struct {
	ID       string
	Passcode string
}

func (s ShareLink) URL() string { return "https://pan.quark.cn/s/" + s.ID }

var (
	shareLinkPattern = regexp.MustCompile(`(?i)https?://pan\.quark\.cn/s/([a-z0-9]+)[^\s，。；"<>]*`)
	passcodePattern  = regexp.MustCompile(`(?:提取码|提取碼|访问码|密[码碼])\s*[:：]?\s*([A-Za-z0-9]{4})(?:[^A-Za-z0-9]|$)`)
)

// ParseShareLink accepts the official URL and the copyable share message.
func ParseShareLink(text string) (ShareLink, error) {
	match := shareLinkPattern.FindStringSubmatch(text)
	if match == nil {
		return ShareLink{}, ErrInvalidShareLink
	}
	link := ShareLink{ID: match[1]}
	if u, err := url.Parse(match[0]); err == nil {
		for _, pair := range strings.Split(u.RawQuery, "&") {
			name, value, _ := strings.Cut(pair, "=")
			name, err := url.PathUnescape(name)
			if err != nil {
				continue
			}
			switch strings.ToLower(name) {
			case "pwd", "passcode", "password", "pw":
				if decoded, err := url.PathUnescape(value); err == nil {
					link.Passcode = decoded
					return link, nil
				}
			}
		}
	}
	if match := passcodePattern.FindStringSubmatch(text); match != nil {
		link.Passcode = match[1]
	}
	return link, nil
}

// ShareSession holds the short-lived token for browsing and saving a share.
type ShareSession struct {
	Link   ShareLink
	SToken string
	Title  string
}

type TaskStatus string

const (
	TaskPending   TaskStatus = "pending"
	TaskCompleted TaskStatus = "completed"
	TaskFailed    TaskStatus = "failed"
)

type TransferTask struct {
	ID            string
	Status        TaskStatus
	SavedFIDs     []string
	FailureReason string
}

// TransferTaskError preserves the task identity for later reconciliation.
type TransferTaskError struct {
	ID     string
	Status TaskStatus
	Reason string
}

func (e *TransferTaskError) Error() string {
	if e.Status == TaskPending {
		return fmt.Sprintf("夸克转存仍在处理中（任务 %s），稍后可继续核对。", e.ID)
	}
	if e.Reason != "" {
		return fmt.Sprintf("上一次夸克转存失败：%s（任务 %s 已停止。）", e.Reason, e.ID)
	}
	return fmt.Sprintf("上一次夸克转存失败（任务 %s 已停止）。", e.ID)
}

// Download holds short-lived access and optional remote integrity metadata.
type Download struct {
	URL       *url.URL
	Headers   http.Header
	FID       string
	Size      *int64
	MD5       string
	UpdatedAt *time.Time
}
