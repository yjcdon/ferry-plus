package quark

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	panHost   = "pan.quark.cn"
	pcHost    = "drive-pc.quark.cn"
	driveHost = "drive.quark.cn"
	referer   = "https://pan.quark.cn/"
	drivePath = "/1/clouddrive"
	userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
)

// Client owns one Quark account's cookies and active request lifetime.
type Client struct {
	http     http.Client
	lifetime context.Context
	cancel   context.CancelFunc
	mu       sync.Mutex
	cookies  []Cookie
	onChange func(Credential) error
}

// New uses the caller's transport and keeps the provider session isolated.
func New(credential Credential, httpClient *http.Client) *Client {
	client := http.Client{Timeout: 60 * time.Second}
	if httpClient != nil {
		client = *httpClient
	}
	client.Jar = nil
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	ctx, cancel := context.WithCancel(context.Background())
	return &Client{http: client, lifetime: ctx, cancel: cancel, cookies: slices.Clone(credential.Cookies)}
}

// Revoke cancels active requests and prevents future use after an account change.
func (c *Client) Revoke() { c.cancel() }

// ObserveCredentialChanges installs the synchronous persistence step for cookie updates.
func (c *Client) ObserveCredentialChanges(handler func(Credential) error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.onChange = handler
}

func (c *Client) requestContext(ctx context.Context) (context.Context, func()) {
	request, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(c.lifetime, cancel)
	if c.lifetime.Err() != nil {
		cancel()
	}
	return request, func() {
		stop()
		cancel()
	}
}

func (c *Client) currentCredential() Credential {
	now := time.Now()
	var current Credential
	for _, cookie := range c.cookies {
		if cookie.current(now) {
			current.Cookies = append(current.Cookies, cookie)
		}
	}
	return current
}

func (c *Client) cookiesFor(endpoint *url.URL) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	var cookies []string
	path := endpoint.Path
	if path == "" {
		path = "/"
	}
	host := strings.ToLower(endpoint.Hostname())
	for _, cookie := range c.cookies {
		domain := strings.TrimPrefix(cookie.Domain, ".")
		domainMatch := host == domain || strings.HasPrefix(cookie.Domain, ".") && strings.HasSuffix(host, "."+domain)
		pathMatch := path == cookie.Path || strings.HasPrefix(path, strings.TrimSuffix(cookie.Path, "/")+"/")
		if cookie.current(now) && domainMatch && pathMatch && (!cookie.Secure || endpoint.Scheme == "https") {
			cookies = append(cookies, cookie.Name+"="+cookie.Value)
		}
	}
	return strings.Join(cookies, "; ")
}

func (c *Client) acceptCookies(endpoint *url.URL, incoming []*http.Cookie) error {
	if len(incoming) == 0 {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	before := c.currentCredential()
	host := strings.ToLower(endpoint.Hostname())
	now := time.Now()
	changed := false
	for _, next := range incoming {
		domain := strings.ToLower(strings.TrimPrefix(next.Domain, "."))
		if domain == "" {
			domain = host
		} else if !quarkDomain(domain) || host != domain && !strings.HasSuffix(host, "."+domain) {
			continue
		}
		if next.Domain != "" {
			domain = "." + domain
		}
		path := next.Path
		if !strings.HasPrefix(path, "/") {
			path = endpoint.Path[:max(0, strings.LastIndex(endpoint.Path, "/"))]
			if path == "" {
				path = "/"
			}
		}
		value := Cookie{Name: next.Name, Value: next.Value, Domain: domain, Path: path, Secure: next.Secure}
		switch {
		case next.MaxAge > 0:
			expires := now.Add(time.Duration(next.MaxAge) * time.Second)
			value.Expires = &expires
		case !next.Expires.IsZero():
			value.Expires = &next.Expires
		}
		sameKey := func(existing Cookie) bool {
			return existing.Name == value.Name && existing.Domain == value.Domain && existing.Path == value.Path
		}
		index := slices.IndexFunc(c.cookies, sameKey)
		if next.MaxAge < 0 || !value.current(now) {
			if index >= 0 {
				c.cookies = slices.Delete(c.cookies, index, index+1)
				changed = true
			}
			continue
		}
		if index < 0 {
			c.cookies = append(c.cookies, value)
			changed = true
		} else {
			previous := c.cookies[index]
			if previous.Value != value.Value || previous.Secure != value.Secure || !sameTime(previous.Expires, value.Expires) {
				c.cookies[index] = value
				changed = true
			}
		}
	}
	if changed && c.onChange != nil {
		if err := c.onChange(c.currentCredential()); err != nil {
			c.cookies = before.Cookies
			return fmt.Errorf("保存夸克登录凭据: %w", err)
		}
	}
	return nil
}

func sameTime(a, b *time.Time) bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.Equal(*b)
}

func (c *Client) send(ctx context.Context, endpoint *url.URL, body []byte) ([]byte, error) {
	ctx, cancel := c.requestContext(ctx)
	defer cancel()
	for range 6 {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if endpoint.Scheme != "https" || endpoint.User != nil || !quarkDomain(strings.ToLower(endpoint.Hostname())) {
			return nil, ErrUnsafeRedirect
		}
		method := http.MethodGet
		if body != nil {
			method = http.MethodPost
		}
		req, err := http.NewRequestWithContext(ctx, method, endpoint.String(), bytes.NewReader(body))
		if err != nil {
			return nil, ErrInvalidResponse
		}
		req.Header.Set("User-Agent", userAgent)
		req.Header.Set("Referer", referer)
		req.Header.Set("Origin", "https://pan.quark.cn")
		req.Header.Set("Accept", "application/json, text/plain, */*")
		if body != nil {
			req.Header.Set("Content-Type", "application/json;charset=UTF-8")
		}
		if cookies := c.cookiesFor(endpoint); cookies != "" {
			req.Header.Set("Cookie", cookies)
		}
		response, err := c.http.Do(req)
		if err != nil {
			return nil, transportError(err)
		}
		if err := c.acceptCookies(endpoint, response.Cookies()); err != nil {
			response.Body.Close()
			return nil, err
		}
		switch response.StatusCode {
		case 301, 302, 303, 307, 308:
			next, err := response.Location()
			response.Body.Close()
			if err != nil {
				return nil, ErrInvalidResponse
			}
			endpoint = next
			if response.StatusCode <= 303 {
				body = nil
			}
			continue
		case http.StatusUnauthorized:
			response.Body.Close()
			return nil, ErrLoginExpired
		}
		if response.StatusCode < 200 || response.StatusCode >= 300 {
			response.Body.Close()
			return nil, HTTPError(response.StatusCode)
		}
		return readBody(response, 8<<20)
	}
	return nil, ErrUnsafeRedirect
}

func transportError(err error) error {
	var requestErr *url.Error
	if errors.As(err, &requestErr) {
		err = requestErr.Err
	}
	return fmt.Errorf("夸克网络请求失败: %w", err)
}

func readBody(response *http.Response, limit int64) ([]byte, error) {
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil {
		return nil, transportError(err)
	}
	if int64(len(data)) > limit {
		return nil, ErrInvalidResponse
	}
	return data, nil
}

type scalar string

func (s *scalar) UnmarshalJSON(data []byte) error {
	if data[0] == '"' {
		var text string
		if err := json.Unmarshal(data, &text); err != nil {
			return err
		}
		*s = scalar(text)
		return nil
	}
	number, err := strconv.ParseInt(string(data), 10, 64)
	if err == nil {
		*s = scalar(strconv.FormatInt(number, 10))
	}
	return err
}

type envelope struct {
	Status   int             `json:"status"`
	Code     *scalar         `json:"code"`
	Success  bool            `json:"success"`
	Message  string          `json:"message"`
	Msg      string          `json:"msg"`
	Data     json.RawMessage `json:"data"`
	Metadata struct {
		Total    *int `json:"_total"`
		PartSize *int `json:"part_size"`
	} `json:"metadata"`
}

func (r envelope) code() string {
	if r.Code != nil {
		return string(*r.Code)
	}
	if r.Status != 0 {
		return strconv.Itoa(r.Status)
	}
	return "unknown"
}

func (r envelope) err() error {
	code := r.code()
	switch code {
	case "401", "403", "41013", "31001", "20002", "NOT_LOGIN", "UNLOGIN", "UNAUTHORIZED":
		return ErrLoginExpired
	}
	message := r.Message
	if message == "" {
		message = r.Msg
	}
	return &ServiceError{Code: code, Message: message}
}

func (r envelope) driveOK() bool { return r.Status == 200 && r.code() == "0" }

func (r envelope) decode(dst any) error {
	if len(r.Data) == 0 || bytes.Equal(r.Data, []byte("null")) || json.Unmarshal(r.Data, dst) != nil {
		return ErrInvalidResponse
	}
	return nil
}

func (c *Client) call(ctx context.Context, host, path string, query url.Values, body any) (envelope, error) {
	var payload []byte
	if body != nil {
		var err error
		payload, err = json.Marshal(body)
		if err != nil {
			return envelope{}, err
		}
	}
	endpoint := &url.URL{Scheme: "https", Host: host, Path: path, RawQuery: query.Encode()}
	data, err := c.send(ctx, endpoint, payload)
	if err != nil {
		return envelope{}, err
	}
	var response *envelope
	if json.Unmarshal(data, &response) != nil || response == nil {
		return envelope{}, ErrInvalidResponse
	}
	return *response, nil
}

func (c *Client) drive(ctx context.Context, host, path string, query url.Values, body any) (envelope, error) {
	params := url.Values{"pr": {"ucpro"}, "fr": {"pc"}, "uc_param_str": {""}}
	for key, values := range query {
		params[key] = values
	}
	return c.call(ctx, host, drivePath+path, params, body)
}

// Validate confirms account identity and checks root access without mutating drive data.
func (c *Client) Validate(ctx context.Context, expectedAccountID string) (Login, error) {
	response, err := c.call(ctx, panHost, "/account/info", url.Values{"fr": {"pc"}, "platform": {"pc"}}, nil)
	if err != nil {
		return Login{}, err
	}
	if !response.Success && response.code() != "OK" {
		return Login{}, response.err()
	}
	var info *struct {
		UID      *scalar `json:"uid"`
		Nickname *string `json:"nickname"`
	}
	if len(response.Data) != 0 && json.Unmarshal(response.Data, &info) != nil {
		return Login{}, ErrInvalidResponse
	}
	if info == nil || info.UID == nil && info.Nickname == nil {
		return Login{}, ErrLoginExpired
	}
	var account Account
	if info.UID != nil {
		account.ID = string(*info.UID)
	} else {
		c.mu.Lock()
		for _, cookie := range c.currentCredential().Cookies {
			if cookie.Name == "__uid" {
				account.ID = cookie.Value
				break
			}
		}
		c.mu.Unlock()
	}
	if account.ID == "" {
		return Login{}, ErrMissingIdentity
	}
	if info.Nickname != nil {
		account.Nickname = *info.Nickname
	}
	if expectedAccountID != "" && account.ID != expectedAccountID {
		return Login{}, ErrAccountChanged
	}
	response, err = c.drive(ctx, pcHost, "/file/sort", url.Values{
		"pdir_fid": {RootFID}, "_page": {"1"}, "_size": {"1"}, "_fetch_total": {"1"},
		"_sort": {"file_type:asc,updated_at:desc"},
	}, nil)
	if err != nil {
		return Login{}, err
	}
	if !response.driveOK() {
		return Login{}, response.err()
	}
	var page struct {
		List []struct{} `json:"list"`
	}
	if err := response.decode(&page); err != nil || page.List == nil {
		return Login{}, ErrInvalidResponse
	}
	c.mu.Lock()
	credential := c.currentCredential()
	c.mu.Unlock()
	if len(credential.Cookies) == 0 {
		return Login{}, ErrMissingCredential
	}
	return Login{Account: account, Credential: credential, VerifiedAt: time.Now()}, nil
}

// Capacity reads both byte counts, including when used exceeds the current entitlement.
func (c *Client) Capacity(ctx context.Context) (Capacity, error) {
	response, err := c.drive(ctx, pcHost, "/member", nil, nil)
	if err != nil {
		return Capacity{}, err
	}
	if !response.driveOK() {
		return Capacity{}, response.err()
	}
	var data struct {
		Total *int64 `json:"total_capacity"`
		Used  *int64 `json:"use_capacity"`
	}
	if err := response.decode(&data); err != nil || data.Total == nil || data.Used == nil || *data.Total < 0 || *data.Used < 0 {
		return Capacity{}, ErrInvalidResponse
	}
	return Capacity{Total: *data.Total, Used: *data.Used}, nil
}
