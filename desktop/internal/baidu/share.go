package baidu

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

type ShareLink struct {
	SURL     string `json:"surl"`
	Password string `json:"password,omitempty"`
}

func (l ShareLink) URL() string { return pan + "/s/1" + l.SURL }

var (
	shareURL          = regexp.MustCompile(`(?i:https?://)?pan\.baidu\.com/[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]*`)
	shareCode         = regexp.MustCompile(`^[0-9A-Za-z_-]{1,22}$`)
	sharePassword     = regexp.MustCompile(`^[0-9A-Za-z]{4}$`)
	shareTextPassword = regexp.MustCompile(`(?:提取码|密码)\s*[:：]?\s*([0-9A-Za-z]{4})(?:[^0-9A-Za-z]|$)`)
	pageFragment      = regexp.MustCompile(`\{.+?loginstate.+?\}`)
	pageType          = regexp.MustCompile(`"errortype"\s*:\s*(-?\d+)`)
	pageToken         = regexp.MustCompile(`"bdstoken"\s*:\s*"([0-9a-f]+)"`)
	pageID            = regexp.MustCompile(`"shareid"\s*:\s*"?(\d+)`)
	pageUK            = regexp.MustCompile(`"share_uk"\s*:\s*"?(\d+)`)
)

// ParseShareLink reads a short link or a share-init URL from copied share text.
func ParseShareLink(text string) (ShareLink, error) {
	raw := shareURL.FindString(text)
	if strings.HasPrefix(raw, "pan.") {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil {
		return ShareLink{}, ErrInvalidShareLink
	}
	query := u.Query()
	var code string
	switch {
	case strings.HasPrefix(u.Path, "/s/1"):
		code, _, _ = strings.Cut(u.Path[len("/s/1"):], "/")
	case strings.HasSuffix(u.Path, "/share/init"):
		code = query.Get("surl")
	}
	if !shareCode.MatchString(code) {
		return ShareLink{}, ErrInvalidShareLink
	}
	password := strings.TrimSpace(query.Get("pwd"))
	if !sharePassword.MatchString(password) {
		password = capture(shareTextPassword, text)
	}
	return ShareLink{code, password}, nil
}

func capture(pattern *regexp.Regexp, text string) string {
	fields := pattern.FindStringSubmatch(text)
	if len(fields) > 1 {
		return fields[1]
	}
	return ""
}

type ShareSession struct {
	Link             ShareLink
	Password         string
	ShareID, ShareUK int64
	BDSToken         string
	Cookies          []Cookie
	DeletedCookies   map[string]bool
}

type ShareEntry struct {
	Entry
	RelativeDirectory string
}

func (e ShareEntry) RelativePath() string {
	if e.RelativeDirectory == "" {
		return e.Name
	}
	return e.RelativeDirectory + "/" + e.Name
}

func (s *ShareSession) apply(cookies []*http.Cookie, now time.Time) bool {
	hasBDCLND := false
	if s.DeletedCookies == nil {
		s.DeletedCookies = map[string]bool{}
	}
	for _, item := range cookies {
		if item.MaxAge < 0 || !item.Expires.IsZero() && !item.Expires.After(now) {
			s.Cookies = slices.DeleteFunc(s.Cookies, func(c Cookie) bool { return c.Name == item.Name })
			s.DeletedCookies[item.Name] = true
		} else {
			s.Cookies = mergeCookie(s.Cookies, Cookie{item.Name, item.Value})
			delete(s.DeletedCookies, item.Name)
			hasBDCLND = hasBDCLND || item.Name == "BDCLND"
		}
	}
	return hasBDCLND
}

func (c *Client) shareCookies(s ShareSession) []Cookie {
	cookies := slices.Clone(c.credential.Cookies)
	for _, item := range s.Cookies {
		cookies = mergeCookie(cookies, item)
	}
	return slices.DeleteFunc(cookies, func(item Cookie) bool { return s.DeletedCookies[item.Name] })
}

// OpenShare opens the provider page, verifies any password and refreshes session fields.
func (c *Client) OpenShare(ctx context.Context, link ShareLink, password string) (ShareSession, error) {
	if !shareCode.MatchString(link.SURL) {
		return ShareSession{}, ErrInvalidShareLink
	}
	password = strings.TrimSpace(password)
	if password == "" {
		password = link.Password
	}
	if password != "" && !sharePassword.MatchString(password) {
		return ShareSession{}, ErrInvalidPassword
	}
	session := ShareSession{Link: link, Password: password}
	initPage, err := c.fetchSharePage(ctx, &session, pan+"/disk/home")
	if err != nil {
		return ShareSession{}, err
	}
	if password == "" {
		if initPage {
			return ShareSession{}, ErrPasswordRequired
		}
		return session, nil
	}
	address := endpoint(pan+"/share/verify", url.Values{"shareid": {decimal(session.ShareID)}, "time": {decimal(c.now().UnixMilli())}, "clienttype": {"1"}, "uk": {decimal(session.ShareUK)}})
	r := request{url: address, ua: macUA, cookies: c.shareCookies(session), headers: http.Header{"Referer": {link.URL()}}}.
		form(url.Values{"pwd": {password}, "vcode": {"null"}, "vcode_str": {"null"}, "bdstoken": {session.BDSToken}})
	r.headers.Set("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
	j, reply, err := c.json(ctx, r)
	if err != nil {
		return ShareSession{}, err
	}
	if code := num(j["errno"]); code != 0 {
		return ShareSession{}, apiError(code, message(j), "verify")
	}
	if reply.status >= 400 {
		return ShareSession{}, HTTPError(reply.status)
	}
	if !session.apply(reply.cookies, c.now()) {
		if randsk := str(j["randsk"]); randsk != "" {
			session.Cookies = mergeCookie(session.Cookies, Cookie{"BDCLND", randsk})
			delete(session.DeletedCookies, "BDCLND")
		}
	}
	_, err = c.fetchSharePage(ctx, &session, endpoint(pan+"/share/init", url.Values{"surl": {link.SURL}}))
	if err != nil {
		return ShareSession{}, err
	}
	return session, nil
}

func (c *Client) fetchSharePage(ctx context.Context, s *ShareSession, referer string) (bool, error) {
	reply, err := c.send(ctx, request{url: s.Link.URL(), ua: netdiskUA, cookies: c.shareCookies(*s), headers: http.Header{"Referer": {referer}}})
	if err != nil {
		return false, err
	}
	s.apply(reply.cookies, c.now())
	html := string(reply.data)
	if reply.status == 404 || strings.Contains(html, "error-404") {
		return false, ErrShareNotFound
	}
	if strings.Contains(html, "platform-non-found") {
		return false, ErrShareExpired
	}
	if reply.status >= 400 {
		return false, HTTPError(reply.status)
	}
	if reply.url.Path == "/wap/error" {
		return false, sharePageError(reply.url.Query().Get("errortype"))
	}
	fragment := pageFragment.FindString(html)
	if fragment == "" {
		return false, ErrLoginStateMissing
	}
	field := func(p *regexp.Regexp) string {
		if s := capture(p, fragment); s != "" {
			return s
		}
		return capture(p, html)
	}
	if kind := field(pageType); kind != "" && kind != "-1" {
		return false, sharePageError(kind)
	}
	token := field(pageToken)
	if token == "" {
		return false, ErrLoginStateMissing
	}
	id, idErr := strconv.ParseInt(field(pageID), 10, 64)
	uk, ukErr := strconv.ParseInt(field(pageUK), 10, 64)
	if idErr != nil || ukErr != nil {
		return false, ErrInvalidResponse
	}
	s.ShareID, s.ShareUK, s.BDSToken = id, uk, token
	return strings.HasSuffix(reply.url.Path, "/init"), nil
}

func sharePageError(code string) error {
	if code == "0" {
		return ErrShareNotFound
	}
	return ErrShareUnavailable
}

func decimal(i int64) string { return strconv.FormatInt(i, 10) }

// ListShare loads a shared root or child directory. Child listing falls back to
// the existing WX endpoint only after a provider response rejects share/list.
func (c *Client) ListShare(ctx context.Context, s ShareSession, directory *ShareEntry) ([]ShareEntry, error) {
	if directory == nil {
		address := endpoint(pan+"/share/list", url.Values{"bdstoken": {s.BDSToken}, "root": {"1"}, "web": {"5"}, "app_id": {panID}, "shorturl": {s.Link.SURL}, "channel": {"chunlei"}})
		j, reply, err := c.json(ctx, request{url: address, ua: macUA, cookies: c.shareCookies(s)})
		if err != nil {
			return nil, err
		}
		code := num(j["errno"])
		if s.Password == "" && (code == -9 || code == 9019) {
			return nil, ErrPasswordRequired
		}
		if code != 0 {
			return nil, apiError(code, message(j), "shareList")
		}
		if reply.status >= 400 {
			return nil, HTTPError(reply.status)
		}
		return shareEntries(j["list"], "")
	}
	entries, err := c.listSharePages(ctx, s, *directory, false)
	if err == nil {
		return entries, nil
	}
	if !isShareResponseError(err) {
		return nil, err
	}
	entries, fallbackErr := c.listSharePages(ctx, s, *directory, true)
	if fallbackErr == nil {
		return entries, nil
	}
	if !isShareResponseError(fallbackErr) {
		return nil, fallbackErr
	}
	return nil, err
}

func isShareResponseError(err error) bool {
	// Transport and cancellation errors retain their underlying error type.
	switch err.(type) {
	case APIError, HTTPError:
		return true
	}
	return errors.Unwrap(err) == nil && !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded)
}

func (c *Client) listSharePages(ctx context.Context, s ShareSession, dir ShareEntry, wx bool) ([]ShareEntry, error) {
	seen := map[int64]bool{}
	entries := []ShareEntry{}
	for page := 1; ; page++ {
		size := 100
		var r request
		if wx {
			size = 1000
			address := endpoint(pan+"/share/wxlist", url.Values{"channel": {"weixin"}, "version": {"2.2.2"}, "clienttype": {"25"}, "web": {"1"}})
			r = request{url: address, ua: "netdisk", cookies: []Cookie{{"BDUSS", c.credential.BDUSS}}}.form(url.Values{
				"shorturl": {s.Link.SURL}, "pwd": {s.Password}, "root": {"0"}, "dir": {dir.Path}, "page": {strconv.Itoa(page)}, "num": {strconv.Itoa(size)}, "order": {"time"},
			})
		} else {
			address := endpoint(pan+"/share/list", url.Values{"channel": {"chunlei"}, "clienttype": {"0"}, "web": {"1"}, "page": {strconv.Itoa(page)},
				"num": {strconv.Itoa(size)}, "dir": {dir.Path}, "t": {strconv.FormatFloat(rand.Float64(), 'f', -1, 64)}, "uk": {decimal(s.ShareUK)},
				"shareid": {decimal(s.ShareID)}, "desc": {"1"}, "order": {"other"}, "bdstoken": {"null"}, "showempty": {"0"}})
			r = request{url: address, ua: macUA, cookies: c.shareCookies(s)}
		}
		j, err := c.checked(ctx, r, "errno", "shareList")
		if err != nil {
			return nil, err
		}
		if wx {
			j = obj(j["data"])
		}
		chunk, err := shareEntries(j["list"], dir.RelativePath())
		if err != nil {
			return nil, err
		}
		duplicate := false
		for _, entry := range chunk {
			if seen[entry.FSID] {
				duplicate = true
				continue
			}
			seen[entry.FSID] = true
			entries = append(entries, entry)
		}
		more := len(chunk) >= size
		if wx && j["has_more"] != nil {
			more = flag(j["has_more"])
		}
		if len(chunk) == 0 || duplicate || !more {
			return entries, nil
		}
	}
}

func shareEntries(v any, relative string) ([]ShareEntry, error) {
	items := list(v)
	if items == nil {
		return nil, ErrInvalidResponse
	}
	entries := make([]ShareEntry, 0, len(items))
	for _, v := range items {
		item := obj(v)
		id, ok := integer(item["fs_id"])
		if !ok {
			continue
		}
		itemPath := str(item["path"])
		name := str(item["server_filename"])
		if name == "" {
			name = path.Base(itemPath)
		}
		if itemPath == "" {
			itemPath = "/" + name
		}
		entries = append(entries, ShareEntry{Entry: Entry{FSID: id, Name: name, Path: itemPath, IsDirectory: flag(item["isdir"]), Size: num(item["size"])}, RelativeDirectory: relative})
	}
	return entries, nil
}

type TransferLimitError struct{ Count, Limit int }

func (e TransferLimitError) Error() string {
	return fmt.Sprintf("转存文件数 %d 超过单次上限 %d。", e.Count, e.Limit)
}

// TransferBatch transfers selected share entries into one remote directory.
func (c *Client) TransferBatch(ctx context.Context, s ShareSession, entries []ShareEntry, directory string) error {
	if len(entries) == 0 {
		return nil
	}
	address := endpoint(pan+"/share/transfer", url.Values{"app_id": {panID}, "channel": {"chunlei"}, "clienttype": {"0"},
		"web": {"1"}, "shareid": {decimal(s.ShareID)}, "from": {decimal(s.ShareUK)}, "bdstoken": {s.BDSToken}})
	ids := make([]string, len(entries))
	for i, e := range entries {
		ids[i] = decimal(e.FSID)
	}
	r := request{url: address, ua: winUA, cookies: c.shareCookies(s), headers: http.Header{"Referer": {s.Link.URL()}}}.
		form(url.Values{"fsidlist": {"[" + strings.Join(ids, ",") + "]"}, "path": {directory}})
	j, reply, err := c.json(ctx, r)
	if err != nil {
		return err
	}
	if reply.status >= 400 {
		return HTTPError(reply.status)
	}
	code, ok := integer(j["errno"])
	if !ok {
		return ErrInvalidResponse
	}
	switch code {
	case 0:
		return nil
	case 4:
		return errors.New("转存失败：目标目录中的文件重复。")
	case 12:
		count, countOK := integer(j["target_file_nums"])
		limit, limitOK := integer(j["target_file_nums_limit"])
		if countOK && limitOK && count > limit {
			return TransferLimitError{int(count), int(limit)}
		}
		if items := list(j["info"]); len(items) > 0 {
			item := obj(items[0])
			if itemCode, ok := integer(item["errno"]); ok {
				code = itemCode
			}
			if code == -30 {
				return fmt.Errorf("转存目录中已有同名的文件或目录“%s”。", path.Base(str(item["path"])))
			}
		}
		return fmt.Errorf("转存失败（错误码 %d）。", code)
	default:
		return apiError(code, message(j), "")
	}
}

// Transfer preserves relative directories, and splits provider-limited batches.
func (c *Client) Transfer(ctx context.Context, s ShareSession, entries []ShareEntry, root string) error {
	directories := map[string]bool{}
	for _, entry := range entries {
		if entry.IsDirectory {
			directories[entry.RelativePath()] = true
		}
	}
	groups := map[string][]ShareEntry{}
	var order []string
	for _, entry := range entries {
		nested := false
		for parent := entry.RelativeDirectory; parent != "" && parent != "." && parent != "/"; parent = path.Dir(parent) {
			if directories[parent] {
				nested = true
				break
			}
		}
		if nested {
			continue
		}
		relative := entry.RelativeDirectory
		if _, ok := groups[relative]; !ok {
			order = append(order, relative)
		}
		groups[relative] = append(groups[relative], entry)
	}
	if err := c.CreateDirectory(ctx, root); err != nil {
		return err
	}
	created := map[string]bool{root: true}
	for _, relative := range order {
		destination := root
		for component := range strings.SplitSeq(relative, "/") {
			if component == "" {
				continue
			}
			if component == "." || component == ".." {
				return ErrInvalidFileName
			}
			destination = path.Join(destination, component)
			if created[destination] {
				continue
			}
			if err := c.CreateDirectory(ctx, destination); err != nil {
				return err
			}
			created[destination] = true
		}
		if err := c.transferLimited(ctx, s, groups[relative], destination); err != nil {
			return err
		}
	}
	return nil
}

func (c *Client) transferLimited(ctx context.Context, s ShareSession, entries []ShareEntry, directory string) error {
	err := c.TransferBatch(ctx, s, entries, directory)
	var limit TransferLimitError
	if !errors.As(err, &limit) {
		return err
	}
	if len(entries) > 1 {
		size := (len(entries) + 1) / 2
		if limit.Limit > 0 && len(entries) > limit.Limit {
			size = limit.Limit
		}
		for chunk := range slices.Chunk(entries, size) {
			if err := c.transferLimited(ctx, s, chunk, directory); err != nil {
				return err
			}
		}
		return nil
	}
	entry := entries[0]
	if !entry.IsDirectory {
		return err
	}
	if entry.Name == "" || entry.Name == "." || entry.Name == ".." || strings.Contains(entry.Name, "/") {
		return ErrInvalidFileName
	}
	child := path.Join(directory, entry.Name)
	if err := c.CreateDirectory(ctx, child); err != nil {
		return err
	}
	children, err := c.ListShare(ctx, s, &entry)
	if err != nil {
		return err
	}
	return c.transferLimited(ctx, s, children, child)
}
