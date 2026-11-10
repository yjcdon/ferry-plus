package baidu

import (
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/json"
	"errors"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"
)

type Entry struct {
	FSID        int64      `json:"fsID"`
	Name        string     `json:"name"`
	Path        string     `json:"path"`
	IsDirectory bool       `json:"isDirectory"`
	Size        int64      `json:"size"`
	ModifiedAt  *time.Time `json:"modifiedAt,omitempty"`
}

type DownloadLink struct {
	URL     *url.URL
	Headers http.Header
	Source  string
}

const (
	DownloadSourceLocate = "locate"
	DownloadSourcePCS    = "pcs"
)

// ListDirectory loads every page of one directory and checks stable entry identities.
func (c *Client) ListDirectory(ctx context.Context, directory string) ([]Entry, error) {
	return c.listDirectory(ctx, directory, make(map[int64]bool))
}

func (c *Client) listDirectory(ctx context.Context, directory string, seen map[int64]bool) ([]Entry, error) {
	const pageSize = 1000
	entries := []Entry{}
	for page := 1; ; page++ {
		address := endpoint(pan+"/api/list", url.Values{"dir": {directory}, "order": {"name"}, "desc": {"0"}, "clienttype": {"0"}, "num": {"1000"}, "page": {strconv.Itoa(page)}})
		j, err := c.checked(ctx, request{url: address, ua: netdiskUA, cookies: c.credential.Cookies}, "errno", "")
		if err != nil {
			return nil, err
		}
		items := list(j["list"])
		if items == nil {
			return nil, ErrInvalidResponse
		}
		for _, v := range items {
			item := obj(v)
			id, ok := integer(item["fs_id"])
			itemPath, _ := item["path"].(string)
			kind, kindOK := integer(item["isdir"])
			if !ok || id <= 0 || seen[id] || !strings.HasPrefix(itemPath, "/") || itemPath == "/" || !kindOK || kind < 0 || kind > 1 {
				return nil, ErrInvalidResponse
			}
			size, sizeOK := integer(item["size"])
			if kind == 1 {
				size = 0
			} else if !sizeOK || size < 0 {
				return nil, ErrInvalidResponse
			}
			name := str(item["server_filename"])
			if name == "" {
				name = path.Base(itemPath)
			}
			var modified *time.Time
			if epoch, ok := integer(item["server_mtime"]); ok {
				t := time.Unix(epoch, 0)
				modified = &t
			}
			seen[id] = true
			entries = append(entries, Entry{id, name, itemPath, kind == 1, size, modified})
		}
		if len(items) < pageSize {
			return entries, nil
		}
	}
}

// ListFilesRecursively walks the selected tree and returns only files.
func (c *Client) ListFilesRecursively(ctx context.Context, directory string) ([]Entry, error) {
	dirs := []string{directory}
	seen := map[int64]bool{}
	var files []Entry
	for len(dirs) > 0 {
		entries, err := c.listDirectory(ctx, dirs[0], seen)
		if err != nil {
			return nil, err
		}
		dirs = dirs[1:]
		for _, entry := range entries {
			if entry.IsDirectory {
				dirs = append(dirs, entry.Path)
			} else {
				files = append(files, entry)
			}
		}
	}
	return files, nil
}

// CreateDirectory creates a directory or accepts an already-existing path.
func (c *Client) CreateDirectory(ctx context.Context, directory string) error {
	_, err := c.makeDirectory(ctx, directory)
	if errors.Is(err, ErrAlreadyExists) {
		return nil
	}
	return err
}

// CreateOwnedDirectory requires a fresh directory and returns its cleanup identity.
func (c *Client) CreateOwnedDirectory(ctx context.Context, directory string) (Entry, error) {
	j, err := c.makeDirectory(ctx, directory)
	if err != nil {
		return Entry{}, err
	}
	id, ok := integer(j["fs_id"])
	if !ok || id <= 0 || str(j["path"]) != directory {
		return Entry{}, ErrInvalidResponse
	}
	return Entry{id, path.Base(directory), directory, true, 0, nil}, nil
}

func (c *Client) makeDirectory(ctx context.Context, directory string) (object, error) {
	address := endpoint(pcs+"/rest/2.0/pcs/file", url.Values{"app_id": {pcsID}, "method": {"mkdir"}, "path": {directory}})
	return c.checked(ctx, request{method: http.MethodPost, url: address, cookies: c.credential.Cookies}, "error_code", "")
}

// Delete moves existing entries to the Baidu recycle bin.
func (c *Client) Delete(ctx context.Context, paths []string) error {
	if len(paths) == 0 {
		return nil
	}
	type item struct {
		Path string `json:"path"`
	}
	payload := struct {
		List []item `json:"list"`
	}{make([]item, len(paths))}
	for i, p := range paths {
		payload.List[i] = item{p}
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	var body bytes.Buffer
	form := multipart.NewWriter(&body)
	if err := form.WriteField("param", string(data)); err != nil {
		return err
	}
	if err := form.Close(); err != nil {
		return err
	}
	address := endpoint(pcs+"/rest/2.0/pcs/file", url.Values{"app_id": {pcsID}, "method": {"delete"}})
	_, err = c.checked(ctx, request{method: http.MethodPost, url: address, cookies: c.credential.Cookies, headers: http.Header{"Content-Type": {form.FormDataContentType()}}, body: &body, length: int64(body.Len())}, "error_code", "")
	if errors.Is(err, ErrFileNotFound) {
		return nil
	}
	return err
}

// RenameWithoutReplacing changes the name once and rejects an existing destination.
func (c *Client) RenameWithoutReplacing(ctx context.Context, oldPath, newName string) error {
	return c.manage(ctx, "rename", oldPath, "", newName)
}

// CopyWithoutReplacing creates an independent copy and rejects an existing destination.
func (c *Client) CopyWithoutReplacing(ctx context.Context, oldPath, directory, newName string) error {
	if directory != "/" && !validPath(directory) {
		return ErrInvalidFileName
	}
	return c.manage(ctx, "copy", oldPath, directory, newName)
}

func (c *Client) manage(ctx context.Context, operation, oldPath, directory, newName string) error {
	if !validPath(oldPath) || newName == "" || newName == "." || newName == ".." || strings.ContainsAny(newName, "/\x00") {
		return ErrInvalidFileName
	}
	account, err := c.Validate(ctx)
	if err != nil {
		return err
	}
	item := map[string]string{"path": oldPath, "newname": newName}
	if directory != "" {
		item["dest"], item["ondup"] = directory, "fail"
	}
	filelist, err := json.Marshal([]map[string]string{item})
	if err != nil {
		return err
	}
	address := endpoint(pan+"/api/filemanager", url.Values{"opera": {operation}, "app_id": {panID}, "clienttype": {"0"}, "web": {"1"}, "bdstoken": {account.BDSToken}})
	r := request{url: address, ua: netdiskUA, cookies: c.credential.Cookies, headers: http.Header{"Referer": {pan + "/"}}}.form(url.Values{"async": {"0"}, "ondup": {"fail"}, "filelist": {string(filelist)}})
	j, reply, err := c.json(ctx, r)
	if err != nil {
		return err
	}
	if reply.status < 200 || reply.status >= 300 {
		return HTTPError(reply.status)
	}
	outer, ok := integer(j["errno"])
	if !ok {
		return ErrInvalidResponse
	}
	if outer != 0 && outer != 12 {
		return apiError(outer, message(j), "")
	}
	items := list(j["info"])
	if len(items) != 1 {
		return ErrInvalidResponse
	}
	actual := obj(items[0])
	code, ok := integer(actual["errno"])
	if !ok || str(actual["path"]) != oldPath {
		return ErrInvalidResponse
	}
	if code != 0 {
		msg := str(actual["errmsg"])
		if msg == "" {
			msg = message(j)
		}
		return apiError(code, msg, "")
	}
	if outer != 0 {
		return apiError(outer, message(j), "")
	}
	return nil
}

func validPath(s string) bool {
	if !strings.HasPrefix(s, "/") || strings.ContainsRune(s, 0) {
		return false
	}
	for part := range strings.SplitSeq(s[1:], "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}

// DownloadLink resolves a signed download URL and uses PCS fallback only when
// the provider declines the signed endpoint or has no usable unencrypted link.
func (c *Client) DownloadLink(ctx context.Context, file string, preference int) (DownloadLink, error) {
	link, err := c.locateDownload(ctx, file, preference)
	if !errors.Is(err, ErrUnauthorized) && !errors.Is(err, ErrNoDownloadLink) {
		return link, err
	}
	address := endpoint(pcs+"/rest/2.0/pcs/file", url.Values{"app_id": {pcsID}, "method": {"download"}, "path": {file}})
	u, err := url.Parse(address)
	if err != nil {
		return DownloadLink{}, err
	}
	return DownloadLink{u, c.downloadHeaders(), DownloadSourcePCS}, nil
}

func (c *Client) locateDownload(ctx context.Context, file string, preference int) (DownloadLink, error) {
	uid := uint64(24)
	if found, _ := c.lookupUID(ctx); found != nil {
		uid = *found
	}
	query := locateQuery(c.credential.BDUSS, uid, c.now().Unix(), file)
	j, err := c.checked(ctx, request{method: http.MethodPost, url: pcs + "/rest/2.0/pcs/file?" + query, ua: netdiskUA, cookies: c.credential.Cookies}, "error_code", "")
	if err != nil {
		return DownloadLink{}, err
	}
	var candidates []*url.URL
	for _, item := range list(j["urls"]) {
		v := obj(item)
		if num(v["encrypt"]) != 0 {
			continue
		}
		u, err := url.Parse(str(v["url"]))
		if err == nil && u.Hostname() != "" && (u.Scheme == "http" || u.Scheme == "https") {
			candidates = append(candidates, u)
		}
	}
	if len(candidates) == 0 {
		return DownloadLink{}, ErrNoDownloadLink
	}
	index := min(max(preference, 0), len(candidates)-1)
	for index+1 < len(candidates) && strings.HasPrefix(candidates[index].Hostname(), "nb.cache") {
		index++
	}
	selected := candidates[index]
	selected.Scheme = "https"
	return DownloadLink{selected, c.downloadHeaders(), DownloadSourceLocate}, nil
}

func (c *Client) downloadHeaders() http.Header {
	return http.Header{"Cookie": {cookieHeader(c.credential.Cookies)}, "User-Agent": {netdiskUA}}
}

func locateQuery(bduss string, uid uint64, now int64, file string) string {
	const secret = "ebrcUYiuxaZv2XGu7KIYKxUrqfnOfpDF"
	dev := strings.ToUpper(md5Text(bduss)) + "|0"
	timestamp := strconv.FormatInt(now, 10)
	first := fmt.Sprintf("%x", sha1.Sum([]byte(bduss)))
	rand := fmt.Sprintf("%x", sha1.Sum([]byte(first+strconv.FormatUint(uid, 10)+secret+timestamp+dev)))
	values := url.Values{"ant": {"1"}, "apn_id": {"1_0"}, "app_id": {panID}, "channel": {"0"}, "check_blue": {"1"},
		"clienttype": {"17"}, "es": {"1"}, "esl": {"1"}, "freeisp": {"0"}, "method": {"locatedownload"},
		"path": {file}, "queryfree": {"0"}, "use": {"0"}, "ver": {"4.0"}}
	return encode(values) + "&time=" + timestamp + "&rand=" + rand + "&devuid=" + url.QueryEscape(dev) + "&cuid=" + url.QueryEscape(dev)
}
