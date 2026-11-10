// Package baidu implements Ferry Drive's Baidu Netdisk protocol.
package baidu

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	pan       = "https://pan.baidu.com"
	pcs       = "https://pcs.baidu.com"
	tieba     = "https://tieba.baidu.com"
	panID     = "250528"
	pcsID     = "266719"
	netdiskUA = "netdisk;P2SP;3.0.0.8;netdisk;11.12.3;ANG-AN00;android-android;10.0;JSbridge4.4.0;jointBridge;1.1.0;"
	macUA     = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/63.0.3239.132 Safari/537.36"
	winUA     = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/76.0.3809.100 Safari/537.36"
)

type Client struct {
	http       *http.Client
	credential Credential
	lifetime   context.Context
	revoke     context.CancelFunc
	now        func() time.Time
	uidMu      sync.Mutex
	uid        *uint64
	uidChecked bool
	uidName    string
}

// New creates a client for one validated credential and supplied transport.
func New(credential Credential, client *http.Client) *Client {
	if client == nil {
		client = &http.Client{Timeout: 50 * time.Second}
	}
	session := *client
	session.Jar = nil
	lifetime, revoke := context.WithCancel(context.Background())
	return &Client{http: &session, credential: credential, lifetime: lifetime, revoke: revoke, now: time.Now}
}

// Revoke cancels outstanding requests and prevents further use of this account session.
func (c *Client) Revoke() { c.revoke() }

type request struct {
	method, url, ua string
	cookies         []Cookie
	headers         http.Header
	body            io.Reader
	length          int64
}

func encode(v url.Values) string { return strings.ReplaceAll(v.Encode(), "+", "%20") }
func endpoint(base string, v url.Values) string {
	if len(v) == 0 {
		return base
	}
	return base + "?" + encode(v)
}

func (r request) form(v url.Values) request {
	body := encode(v)
	r.method, r.body, r.length = http.MethodPost, strings.NewReader(body), int64(len(body))
	if r.headers == nil {
		r.headers = make(http.Header)
	}
	r.headers.Set("Content-Type", "application/x-www-form-urlencoded")
	return r
}

type response struct {
	status  int
	url     *url.URL
	cookies []*http.Cookie
	data    []byte
}

func (c *Client) send(ctx context.Context, r request) (response, error) {
	if err := c.lifetime.Err(); err != nil {
		return response{}, err
	}
	ctx, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(c.lifetime, cancel)
	defer stop()
	defer cancel()
	if r.method == "" {
		r.method = http.MethodGet
	}
	req, err := http.NewRequestWithContext(ctx, r.method, r.url, r.body)
	if err != nil {
		return response{}, fmt.Errorf("创建百度请求: %w", err)
	}
	req.ContentLength = r.length
	if r.headers != nil {
		req.Header = r.headers.Clone()
	}
	if r.ua != "" {
		req.Header.Set("User-Agent", r.ua)
	}
	if len(r.cookies) > 0 {
		req.Header.Set("Cookie", cookieHeader(r.cookies))
	}
	reply, err := c.http.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return response{}, ctx.Err()
		}
		// net/http errors include the full URL, which can contain short-lived tokens.
		var urlErr *url.Error
		if errors.As(err, &urlErr) {
			err = urlErr.Err
		}
		return response{}, fmt.Errorf("百度网络请求失败: %w", err)
	}
	defer reply.Body.Close()
	data, err := io.ReadAll(reply.Body)
	if err != nil {
		return response{}, fmt.Errorf("读取百度响应: %w", err)
	}
	finalURL := req.URL
	if reply.Request != nil {
		finalURL = reply.Request.URL
	}
	return response{reply.StatusCode, finalURL, reply.Cookies(), data}, nil
}

type object map[string]any

func obj(v any) object { m, _ := v.(map[string]any); return m }
func list(v any) []any { a, _ := v.([]any); return a }
func str(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case json.Number:
		return x.String()
	}
	return ""
}

func integer(v any) (int64, bool) {
	n, err := strconv.ParseInt(str(v), 10, 64)
	return n, err == nil
}

func num(v any) int64 { n, _ := integer(v); return n }
func flag(v any) bool {
	if x, ok := v.(bool); ok {
		return x
	}
	return num(v) != 0 || strings.EqualFold(str(v), "true")
}
func message(j object) string {
	if s := str(j["show_msg"]); s != "" {
		return s
	}
	return str(j["errmsg"])
}

func (c *Client) json(ctx context.Context, r request) (object, response, error) {
	reply, err := c.send(ctx, r)
	if err != nil {
		return nil, reply, err
	}
	var j object
	decoder := json.NewDecoder(bytes.NewReader(reply.data))
	decoder.UseNumber()
	if err := decoder.Decode(&j); err != nil || j == nil || decoder.Decode(new(any)) != io.EOF {
		if reply.status >= 400 {
			return nil, reply, HTTPError(reply.status)
		}
		return nil, reply, ErrInvalidResponse
	}
	return j, reply, nil
}

func (c *Client) checked(ctx context.Context, r request, field, operation string) (object, error) {
	j, reply, err := c.json(ctx, r)
	if err != nil {
		return nil, err
	}
	code, present := integer(j[field])
	if present && code != 0 {
		msg := message(j)
		if field == "error_code" {
			msg = str(j["error_msg"])
		}
		err := apiError(code, msg, operation)
		if operation == "mkdir" {
			err = errors.Join(ErrDirectoryCreationRejected, err)
		}
		return nil, err
	}
	if reply.status >= 400 {
		return nil, HTTPError(reply.status)
	}
	return j, nil
}
