package quark

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode"
)

// ListDirectory reads a complete directory or returns the first page failure.
func (c *Client) ListDirectory(ctx context.Context, parentFID string) ([]Entry, error) {
	return c.list(ctx, pcHost, "/file/sort", url.Values{
		"pdir_fid": {parentFID}, "fetch_all_file": {"1"}, "fetch_risk_file_name": {"1"},
		"_sort": {"file_type:asc,file_name:asc"},
	}, false)
}

type fileItem struct {
	FID           string   `json:"fid"`
	Name          string   `json:"file_name"`
	Directory     *bool    `json:"dir"`
	File          *bool    `json:"file"`
	Type          *int     `json:"file_type"`
	Size          *int64   `json:"size"`
	Updated       *float64 `json:"updated_at"`
	LegacyUpdated *float64 `json:"l_updated_at"`
	MD5           string   `json:"md5"`
	ShareToken    string   `json:"share_fid_token"`
	Parent        *string  `json:"pdir_fid"`
}

func (f fileItem) entry() (Entry, error) {
	if f.FID == "" || f.Name == "" {
		return Entry{}, ErrInvalidResponse
	}
	entry := Entry{FID: f.FID, Name: f.Name, MD5: f.MD5, ShareFIDToken: f.ShareToken}
	switch {
	case f.Directory != nil:
		entry.IsDirectory = *f.Directory
	case f.File != nil:
		entry.IsDirectory = !*f.File
	case f.Type != nil:
		entry.IsDirectory = *f.Type == 0
	default:
		return Entry{}, ErrInvalidResponse
	}
	if f.Size == nil && !entry.IsDirectory || f.Size != nil && *f.Size < 0 {
		return Entry{}, ErrInvalidResponse
	}
	if f.Size != nil {
		entry.Size = *f.Size
	}
	if f.Parent != nil {
		entry.ParentFID = *f.Parent
	}
	if f.Updated != nil {
		entry.UpdatedAt = milliseconds(f.Updated)
	} else {
		entry.UpdatedAt = milliseconds(f.LegacyUpdated)
	}
	return entry, nil
}

func milliseconds(value *float64) *time.Time {
	if value == nil {
		return nil
	}
	ms := int64(*value)
	t := time.UnixMilli(ms)
	return &t
}

func (c *Client) list(ctx context.Context, host, path string, query url.Values, virtualRoot bool) ([]Entry, error) {
	parent := query.Get("pdir_fid")
	if parent == "" {
		return nil, ErrInvalidSelection
	}
	const pageSize = 100
	query.Set("_size", strconv.Itoa(pageSize))
	query.Set("_fetch_total", "1")
	entries := []Entry{}
	seen := make(map[string]bool)
	for page := 1; page <= 10_000; page++ {
		query.Set("_page", strconv.Itoa(page))
		response, err := c.drive(ctx, host, path, query, nil)
		if err != nil {
			return nil, err
		}
		if !response.driveOK() {
			return nil, response.err()
		}
		var data struct {
			List []fileItem `json:"list"`
		}
		if err := response.decode(&data); err != nil || data.List == nil {
			return nil, ErrInvalidResponse
		}
		for _, file := range data.List {
			entry, err := file.entry()
			if err != nil || !virtualRoot && file.Parent != nil && *file.Parent != parent || seen[entry.FID] {
				return nil, ErrInvalidResponse
			}
			seen[entry.FID] = true
			entries = append(entries, entry)
		}
		if total := response.Metadata.Total; total != nil {
			switch {
			case *total < len(entries):
				return nil, ErrInvalidResponse
			case *total == len(entries):
				return entries, nil
			case len(data.List) == 0:
				return nil, ErrInvalidResponse
			}
		} else if len(data.List) < pageSize {
			return entries, nil
		}
	}
	return nil, ErrInvalidResponse
}

func validName(name string) bool {
	return name != "" && name != "." && name != ".." && !strings.ContainsAny(name, "/\x00")
}

func (c *Client) CreateDirectory(ctx context.Context, name, parentFID string) (string, error) {
	if !validName(name) || parentFID == "" {
		return "", ErrInvalidSelection
	}
	response, err := c.drive(ctx, pcHost, "/file", nil, map[string]any{
		"dir_init_lock": false, "dir_path": "", "file_name": name, "pdir_fid": parentFID,
	})
	if err != nil {
		return "", err
	}
	if !response.driveOK() {
		return "", response.err()
	}
	var data struct {
		FID string `json:"fid"`
	}
	if err := response.decode(&data); err != nil || data.FID == "" || data.FID == RootFID {
		return "", ErrInvalidResponse
	}
	return data.FID, nil
}

func (c *Client) Rename(ctx context.Context, fid, newName string) error {
	if fid == "" || fid == RootFID || !validName(newName) || strings.TrimSpace(newName) == "" ||
		strings.Contains(newName, "\\") || strings.ContainsFunc(newName, unicode.IsControl) {
		return ErrInvalidSelection
	}
	return c.mutate(ctx, pcHost, "/file/rename", map[string]any{"fid": fid, "file_name": newName})
}

// Delete moves only the supplied file identities to Quark's recycle bin.
func (c *Client) Delete(ctx context.Context, fids []string) error {
	if len(fids) == 0 {
		return ErrInvalidSelection
	}
	for _, fid := range fids {
		if fid == "" || fid == RootFID {
			return ErrInvalidSelection
		}
	}
	return c.mutate(ctx, driveHost, "/file/delete", map[string]any{"action_type": 1, "filelist": fids, "exclude_fids": []string{}})
}

func (c *Client) mutate(ctx context.Context, host, path string, body any) error {
	response, err := c.drive(ctx, host, path, nil, body)
	if err != nil {
		return err
	}
	if !response.driveOK() {
		return response.err()
	}
	if len(response.Data) == 0 || bytes.Equal(response.Data, []byte("null")) {
		return nil
	}
	var receipt struct {
		ID string `json:"task_id"`
	}
	if err := response.decode(&receipt); err != nil {
		return err
	}
	if receipt.ID != "" {
		_, err = c.WaitForTask(ctx, receipt.ID, 60, time.Second)
	}
	return err
}

func (c *Client) OpenShare(ctx context.Context, link ShareLink) (ShareSession, error) {
	if link.ID == "" {
		return ShareSession{}, ErrInvalidShareLink
	}
	response, err := c.drive(ctx, panHost, "/share/sharepage/token", nil,
		map[string]string{"pwd_id": link.ID, "passcode": link.Passcode})
	if err != nil {
		return ShareSession{}, err
	}
	if !response.driveOK() {
		switch response.code() {
		case "41008":
			return ShareSession{}, ErrShareRequiresCode
		case "41007", "41009", "24000":
			return ShareSession{}, ErrInvalidPasscode
		case "41010", "41012", "24001":
			return ShareSession{}, ErrShareUnavailable
		default:
			return ShareSession{}, response.err()
		}
	}
	var token struct {
		Value string  `json:"stoken"`
		Title *string `json:"title"`
	}
	if err := response.decode(&token); err != nil || token.Value == "" {
		return ShareSession{}, ErrInvalidResponse
	}
	title := "夸克分享"
	if token.Title != nil {
		title = *token.Title
	}
	return ShareSession{Link: link, SToken: token.Value, Title: title}, nil
}

func (c *Client) ListShareDirectory(ctx context.Context, session ShareSession, parentFID string) ([]Entry, error) {
	if session.Link.ID == "" || session.SToken == "" {
		return nil, ErrInvalidSelection
	}
	return c.list(ctx, panHost, "/share/sharepage/detail", url.Values{
		"pwd_id": {session.Link.ID}, "stoken": {session.SToken}, "pdir_fid": {parentFID},
		"force": {"0"}, "_fetch_sub_dirs": {"0"}, "_sort": {"file_type:asc,file_name:asc"},
	}, parentFID == RootFID)
}

// SubmitSave returns the service task identity for persistence before waiting.
func (c *Client) SubmitSave(ctx context.Context, session ShareSession, entries []Entry, destinationFID, parentFID string) (string, error) {
	if session.Link.ID == "" || session.SToken == "" || len(entries) == 0 || destinationFID == "" || parentFID == "" {
		return "", ErrInvalidSelection
	}
	fids, tokens := make([]string, 0, len(entries)), make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.FID == "" || entry.ShareFIDToken == "" {
			return "", ErrInvalidSelection
		}
		fids = append(fids, entry.FID)
		tokens = append(tokens, entry.ShareFIDToken)
	}
	response, err := c.drive(ctx, pcHost, "/share/sharepage/save", nil, map[string]any{
		"fid_list": fids, "fid_token_list": tokens, "to_pdir_fid": destinationFID,
		"pwd_id": session.Link.ID, "stoken": session.SToken, "pdir_fid": parentFID, "scene": "link",
	})
	if err != nil {
		return "", err
	}
	if !response.driveOK() {
		return "", response.err()
	}
	var data struct {
		ID string `json:"task_id"`
	}
	if err := response.decode(&data); err != nil || data.ID == "" {
		return "", ErrInvalidResponse
	}
	return data.ID, nil
}

func (c *Client) QueryTask(ctx context.Context, id string, retryIndex int) (TransferTask, error) {
	if id == "" || retryIndex < 0 {
		return TransferTask{}, ErrInvalidSelection
	}
	response, err := c.drive(ctx, pcHost, "/task", url.Values{"task_id": {id}, "retry_index": {strconv.Itoa(retryIndex)}}, nil)
	if err != nil {
		return TransferTask{}, err
	}
	var data struct {
		ID     string `json:"task_id"`
		Status *int   `json:"status"`
		Save   *struct {
			FIDs []string `json:"save_as_top_fids"`
		} `json:"save_as"`
	}
	decodeErr := response.decode(&data)
	if !response.driveOK() {
		serviceErr := response.err()
		if !errors.Is(serviceErr, ErrLoginExpired) && decodeErr == nil && data.ID == id &&
			data.Status != nil && (*data.Status == 3 || *data.Status == 4) {
			return TransferTask{ID: id, Status: TaskFailed, FailureReason: serviceErr.Error()}, nil
		}
		return TransferTask{}, serviceErr
	}
	if decodeErr != nil || data.Status == nil || data.Save != nil && data.Save.FIDs == nil {
		return TransferTask{}, ErrInvalidResponse
	}
	task := TransferTask{ID: id}
	switch *data.Status {
	case 0, 1:
		task.Status = TaskPending
	case 2:
		task.Status = TaskCompleted
	case 3, 4:
		if data.ID != id {
			return TransferTask{}, ErrInvalidResponse
		}
		task.Status = TaskFailed
	default:
		return TransferTask{}, ErrInvalidResponse
	}
	if data.Save != nil {
		task.SavedFIDs = data.Save.FIDs
	}
	return task, nil
}

// WaitForTask uses bounded, cancelable polling. Stopping does not cancel the remote task.
func (c *Client) WaitForTask(ctx context.Context, id string, maxAttempts int, interval time.Duration) (TransferTask, error) {
	if maxAttempts <= 0 || interval <= 0 {
		return TransferTask{}, ErrInvalidSelection
	}
	ctx, cancel := c.requestContext(ctx)
	defer cancel()
	for attempt := range maxAttempts {
		task, err := c.QueryTask(ctx, id, attempt)
		if err != nil {
			return TransferTask{}, err
		}
		switch task.Status {
		case TaskCompleted:
			return task, nil
		case TaskFailed:
			return TransferTask{}, &TransferTaskError{ID: id, Status: TaskFailed, Reason: task.FailureReason}
		}
		if attempt+1 < maxAttempts {
			timer := time.NewTimer(interval)
			select {
			case <-ctx.Done():
				timer.Stop()
				return TransferTask{}, ctx.Err()
			case <-timer.C:
			}
		}
	}
	return TransferTask{}, &TransferTaskError{ID: id, Status: TaskPending}
}

// Download requests the original file, not a video transcode.
func (c *Client) Download(ctx context.Context, fid string) (Download, error) {
	if fid == "" || fid == RootFID {
		return Download{}, ErrInvalidSelection
	}
	response, err := c.drive(ctx, driveHost, "/file/download", nil, map[string][]string{"fids": {fid}})
	if err != nil {
		return Download{}, err
	}
	if !response.driveOK() {
		return Download{}, response.err()
	}
	var items []struct {
		FID     *string  `json:"fid"`
		URL     string   `json:"download_url"`
		Size    *int64   `json:"size"`
		MD5     string   `json:"md5"`
		Updated *float64 `json:"updated_at"`
	}
	if err := response.decode(&items); err != nil || len(items) != 1 ||
		items[0].FID != nil && *items[0].FID != fid {
		return Download{}, ErrInvalidResponse
	}
	item := items[0]
	endpoint, err := url.Parse(item.URL)
	if err != nil || endpoint.Scheme != "https" || endpoint.Hostname() == "" || endpoint.User != nil ||
		item.Size != nil && *item.Size < 0 {
		return Download{}, ErrInvalidResponse
	}
	headers := http.Header{"User-Agent": {userAgent}, "Referer": {referer}}
	if cookie := c.cookiesFor(endpoint); cookie != "" {
		headers.Set("Cookie", cookie)
	}
	return Download{URL: endpoint, Headers: headers, FID: fid, Size: item.Size, MD5: item.MD5, UpdatedAt: milliseconds(item.Updated)}, nil
}
