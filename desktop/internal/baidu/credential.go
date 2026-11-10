package baidu

import (
	"slices"
	"strings"
	"time"
)

type Cookie struct {
	Name  string
	Value string
}
type Credential struct {
	BDUSS   string
	STOKEN  string
	Cookies []Cookie
}

// BrowserCookie contains the browser metadata needed to select cookies sent to the netdisk root.
type BrowserCookie struct {
	Cookie
	Domain, Path     string
	Expires, Created time.Time
}

// ParseCredential accepts a copied Cookie header. The last duplicate wins.
func ParseCredential(text string) (Credential, error) {
	text = strings.TrimSpace(text)
	if strings.HasPrefix(strings.ToLower(text), "cookie:") {
		text = text[len("cookie:"):]
	}
	var cookies []Cookie
	for segment := range strings.SplitSeq(text, ";") {
		name, value, ok := strings.Cut(segment, "=")
		name = strings.TrimSpace(name)
		if ok && name != "" {
			cookies = mergeCookie(cookies, Cookie{name, unquote(strings.TrimSpace(value))})
		}
	}
	return fromCookies(cookies)
}

// CredentialFromCookies selects the first browser-ordered cookie sent to https://pan.baidu.com/.
func CredentialFromCookies(input []BrowserCookie, now time.Time) (Credential, error) {
	var ordered []BrowserCookie
	for _, item := range input {
		domain := strings.ToLower(item.Domain)
		if item.Name == "" || item.Path != "" && item.Path != "/" ||
			!item.Expires.IsZero() && !item.Expires.After(now) ||
			domain != "pan.baidu.com" && !(strings.HasPrefix(domain, ".") &&
				(domain[1:] == "pan.baidu.com" || strings.HasSuffix("pan.baidu.com", domain))) {
			continue
		}
		ordered = append(ordered, item)
	}
	// Prefer the longer path, then creation time when the browser supplies it.
	slices.SortStableFunc(ordered, func(a, b BrowserCookie) int {
		if len(a.Path) != len(b.Path) {
			return len(b.Path) - len(a.Path)
		}
		if !a.Created.IsZero() && !b.Created.IsZero() {
			return a.Created.Compare(b.Created)
		}
		return 0
	})
	cookies := make([]Cookie, 0, len(ordered))
	seen := map[string]bool{}
	for _, item := range ordered {
		if seen[item.Name] {
			continue
		}
		seen[item.Name] = true
		cookies = append(cookies, Cookie{item.Name, unquote(item.Value)})
	}
	return fromCookies(cookies)
}

func fromCookies(cookies []Cookie) (Credential, error) {
	c := Credential{Cookies: cookies}
	for _, item := range cookies {
		switch item.Name {
		case "BDUSS":
			c.BDUSS = item.Value
		case "STOKEN":
			c.STOKEN = item.Value
		}
	}
	if c.BDUSS == "" {
		return Credential{}, ErrMissingBDUSS
	}
	if c.STOKEN == "" {
		return Credential{}, ErrMissingSTOKEN
	}
	return c, nil
}

func unquote(s string) string {
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		return s[1 : len(s)-1]
	}
	return s
}
func mergeCookie(cookies []Cookie, c Cookie) []Cookie {
	for i, item := range cookies {
		if item.Name == c.Name {
			cookies[i] = c
			return cookies
		}
	}
	return append(cookies, c)
}
func cookieHeader(cookies []Cookie) string {
	values := make([]string, len(cookies))
	for i, c := range cookies {
		values[i] = c.Name + "=" + c.Value
	}
	return strings.Join(values, "; ")
}
