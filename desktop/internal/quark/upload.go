package quark

import (
	"bytes"
	"cmp"
	"context"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

var (
	storageHostPattern = regexp.MustCompile(`^[a-zA-Z0-9.-]+\.quark\.cn$`)
	bucketPattern      = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)
)

// UploadSession contains the stable multipart identity and negotiated boundaries.
type UploadSession struct {
	TaskID      string `json:"taskID"`
	FileID      string `json:"fileID"`
	UploadID    string `json:"uploadID"`
	ObjectKey   string `json:"objectKey"`
	Bucket      string `json:"bucket"`
	StorageHost string `json:"storageHost"`
	ParentFID   string `json:"parentFID"`
	Name        string `json:"name"`
	Size        int64  `json:"size"`
	PartSize    int    `json:"partSize"`
}

func (s UploadSession) valid() bool {
	return s.TaskID != "" && s.FileID != "" && s.FileID != RootFID && s.UploadID != "" && s.ObjectKey != "" &&
		s.ParentFID != "" && validName(s.Name) && s.Size >= 0 && s.PartSize > 0 && s.PartSize <= 64<<20 &&
		storageHostPattern.MatchString(s.StorageHost) && bucketPattern.MatchString(s.Bucket) &&
		!strings.ContainsAny(s.ObjectKey+s.UploadID, "\r\n") &&
		(s.Size == 0 || (s.Size-1)/int64(s.PartSize) < 10_000)
}

// UnmarshalJSON applies the same constraints to recovered and fresh sessions.
func (s *UploadSession) UnmarshalJSON(data []byte) error {
	type stored UploadSession
	var decoded stored
	if err := json.Unmarshal(data, &decoded); err != nil {
		return err
	}
	if !UploadSession(decoded).valid() {
		return ErrInvalidResponse
	}
	*s = UploadSession(decoded)
	return nil
}

func (s UploadSession) PartCount() int {
	if s.Size == 0 {
		return 1
	}
	return int((s.Size-1)/int64(s.PartSize) + 1)
}

func (s UploadSession) partLength(number int) int {
	return int(min(int64(s.PartSize), s.Size-int64(number-1)*int64(s.PartSize)))
}

// UploadAuthorization is an opaque secret; persist Encoded only via encrypted credentials.
type UploadAuthorization struct {
	info     string
	callback []byte
}

type uploadSecret struct {
	Info     string `json:"authInfo"`
	Callback []byte `json:"callback"`
}

func (a UploadAuthorization) Encoded() ([]byte, error) {
	return json.Marshal(uploadSecret{Info: a.info, Callback: a.callback})
}

func DecodeUploadAuthorization(data []byte) (UploadAuthorization, error) {
	var secret uploadSecret
	if err := json.Unmarshal(data, &secret); err != nil || secret.Info == "" || !validCallback(secret.Callback) {
		return UploadAuthorization{}, ErrInvalidResponse
	}
	return UploadAuthorization{info: secret.Info, callback: secret.Callback}, nil
}

func validCallback(value []byte) bool {
	return len(value) > 0 && value[0] == '{' && json.Valid(value)
}

type UploadPreparation struct {
	Session       UploadSession
	Authorization UploadAuthorization
}

type UploadHashResult string

const (
	RequiresTransfer UploadHashResult = "requiresTransfer"
	InstantCompleted UploadHashResult = "instantCompleted"
)

type UploadPartReceipt struct {
	UploadID string `json:"uploadID"`
	Number   int    `json:"number"`
	Size     int    `json:"size"`
	ETag     string `json:"etag"`
}

type StorageError struct {
	Status    int
	Code      string
	RequestID string
}

func (e *StorageError) Error() string {
	code, request := e.Code, e.RequestID
	if code == "" {
		code = "无业务码"
	}
	if request == "" {
		request = "无回执"
	}
	return fmt.Sprintf("夸克对象存储请求失败（HTTP %d，%s，请求 %s）。", e.Status, code, request)
}

func (c *Client) uploadCall(ctx context.Context, path string, body any, result any) (envelope, error) {
	response, err := c.drive(ctx, pcHost, path, nil, body)
	if err != nil {
		return envelope{}, err
	}
	if !response.driveOK() {
		return envelope{}, response.err()
	}
	return response, response.decode(result)
}

// PrepareUpload starts one file's upload and negotiates the exact part length.
func (c *Client) PrepareUpload(ctx context.Context, name, parentFID string, size int64, createdAt, modifiedAt time.Time) (UploadPreparation, error) {
	if !validName(name) || parentFID == "" || size < 0 {
		return UploadPreparation{}, ErrInvalidSelection
	}
	var data struct {
		TaskID    string          `json:"task_id"`
		FID       string          `json:"fid"`
		UploadID  string          `json:"upload_id"`
		ObjectKey string          `json:"obj_key"`
		Bucket    string          `json:"bucket"`
		URL       string          `json:"upload_url"`
		Info      string          `json:"auth_info"`
		Callback  json.RawMessage `json:"callback"`
	}
	response, err := c.uploadCall(ctx, "/file/upload/pre", map[string]any{
		"ccp_hash_update": true, "dir_name": "", "file_name": name, "format_type": "application/octet-stream",
		"l_created_at": createdAt.UnixMilli(), "l_updated_at": modifiedAt.UnixMilli(), "pdir_fid": parentFID, "size": size,
	}, &data)
	if err != nil {
		return UploadPreparation{}, err
	}
	endpoint, err := url.Parse(data.URL)
	if err != nil || endpoint.Scheme != "http" && endpoint.Scheme != "https" || endpoint.User != nil ||
		endpoint.Port() != "" || endpoint.RawQuery != "" || endpoint.ForceQuery || endpoint.Fragment != "" ||
		response.Metadata.PartSize == nil || data.Info == "" || !validCallback(data.Callback) {
		return UploadPreparation{}, ErrInvalidResponse
	}
	session := UploadSession{
		TaskID: data.TaskID, FileID: data.FID, UploadID: data.UploadID, ObjectKey: data.ObjectKey,
		Bucket: data.Bucket, StorageHost: endpoint.Hostname(), ParentFID: parentFID, Name: name,
		Size: size, PartSize: *response.Metadata.PartSize,
	}
	if !session.valid() {
		return UploadPreparation{}, ErrInvalidResponse
	}
	var callback bytes.Buffer
	if err := json.Compact(&callback, data.Callback); err != nil {
		return UploadPreparation{}, ErrInvalidResponse
	}
	return UploadPreparation{Session: session, Authorization: UploadAuthorization{info: data.Info, callback: callback.Bytes()}}, nil
}

func (c *Client) NegotiateUploadHash(ctx context.Context, session UploadSession, md5Hex, sha1Hex string) (UploadHashResult, error) {
	if !session.valid() || !validHex(md5Hex, 32) || !validHex(sha1Hex, 40) {
		return "", ErrInvalidSelection
	}
	var data struct {
		Finished *bool `json:"finish"`
	}
	_, err := c.uploadCall(ctx, "/file/update/hash", map[string]string{
		"task_id": session.TaskID, "md5": strings.ToLower(md5Hex), "sha1": strings.ToLower(sha1Hex),
	}, &data)
	if err != nil {
		return "", err
	}
	if data.Finished == nil {
		return "", ErrInvalidResponse
	}
	if *data.Finished {
		return InstantCompleted, nil
	}
	return RequiresTransfer, nil
}

// UploadPart uploads exactly one bounded part and verifies the receipt against its content.
func (c *Client) UploadPart(ctx context.Context, session UploadSession, auth UploadAuthorization, number int, data []byte) (UploadPartReceipt, error) {
	if !session.valid() || number < 1 || number > session.PartCount() || len(data) != session.partLength(number) {
		return UploadPartReceipt{}, ErrInvalidSelection
	}
	query := url.Values{"partNumber": {strconv.Itoa(number)}, "uploadId": {session.UploadID}}
	_, header, err := c.storageRequest(ctx, session, auth, http.MethodPut, "application/octet-stream", query, query, data, "")
	if err != nil {
		return UploadPartReceipt{}, err
	}
	etag := header.Get("ETag")
	digest := md5.Sum(data)
	if !strings.EqualFold(unquoteETag(etag), hex.EncodeToString(digest[:])) {
		return UploadPartReceipt{}, ErrInvalidResponse
	}
	return UploadPartReceipt{UploadID: session.UploadID, Number: number, Size: len(data), ETag: etag}, nil
}

// ListUploadParts reads all retained parts, checking their identity, ordering and length.
func (c *Client) ListUploadParts(ctx context.Context, session UploadSession, auth UploadAuthorization) ([]UploadPartReceipt, error) {
	if !session.valid() {
		return nil, ErrInvalidSelection
	}
	signedQuery := url.Values{"uploadId": {session.UploadID}}
	query := url.Values{"uploadId": {session.UploadID}, "max-parts": {"1000"}}
	marker, actualBucket := 0, ""
	var receipts []UploadPartReceipt
	for range session.PartCount() + 1 {
		if marker > 0 {
			query.Set("part-number-marker", strconv.Itoa(marker))
		}
		data, header, err := c.storageRequest(ctx, session, auth, http.MethodGet, "", query, signedQuery, nil, "")
		if err != nil {
			return nil, err
		}
		if e := parseStorageError(http.StatusOK, data, header); e != nil {
			return nil, e
		}
		page, err := parsePartsPage(data, session, marker)
		if err != nil || actualBucket != "" && actualBucket != page.bucket {
			return nil, ErrInvalidResponse
		}
		actualBucket = page.bucket
		receipts = append(receipts, page.receipts...)
		if !page.truncated {
			return receipts, nil
		}
		marker = page.next
	}
	return nil, ErrInvalidResponse
}

// CompleteUploadParts merges the exact receipt set. FinishUpload still must acknowledge the merge.
func (c *Client) CompleteUploadParts(ctx context.Context, session UploadSession, auth UploadAuthorization, receipts []UploadPartReceipt) error {
	if !session.valid() || len(receipts) != session.PartCount() {
		return ErrInvalidSelection
	}
	sorted := slices.Clone(receipts)
	slices.SortFunc(sorted, func(a, b UploadPartReceipt) int { return cmp.Compare(a.Number, b.Number) })
	var body bytes.Buffer
	body.WriteString(xml.Header[:len(xml.Header)-1])
	body.WriteString("<CompleteMultipartUpload>")
	for index, receipt := range sorted {
		if receipt.UploadID != session.UploadID || receipt.Number != index+1 || receipt.Size != session.partLength(index+1) ||
			!validHex(unquoteETag(receipt.ETag), 32) {
			return ErrInvalidSelection
		}
		fmt.Fprintf(&body, "<Part><PartNumber>%d</PartNumber><ETag>", receipt.Number)
		// The validated tag is hex, with optional paired quotes.
		body.WriteString(strings.ReplaceAll(receipt.ETag, `"`, "&quot;"))
		body.WriteString("</ETag></Part>")
	}
	body.WriteString("</CompleteMultipartUpload>")
	query := url.Values{"uploadId": {session.UploadID}}
	data, header, err := c.storageRequest(ctx, session, auth, http.MethodPost, "application/xml", query, query, body.Bytes(),
		base64.StdEncoding.EncodeToString(auth.callback))
	if err != nil {
		return err
	}
	if failure := parseStorageError(http.StatusOK, data, header); failure != nil {
		return failure
	}
	return nil
}

func (c *Client) FinishUpload(ctx context.Context, session UploadSession) error {
	if !session.valid() {
		return ErrInvalidSelection
	}
	var data struct{}
	_, err := c.uploadCall(ctx, "/file/upload/finish", map[string]string{"obj_key": session.ObjectKey, "task_id": session.TaskID}, &data)
	return err
}

const ossAgent = "aliyun-sdk-js/6.6.1 Chrome 98.0.4758.80 on Windows 10 64-bit"

func (c *Client) storageRequest(ctx context.Context, session UploadSession, auth UploadAuthorization,
	method, contentType string, query, signedQuery url.Values, body []byte, callback string,
) ([]byte, http.Header, error) {
	if auth.info == "" || !validCallback(auth.callback) {
		return nil, nil, ErrInvalidSelection
	}
	ctx, cancel := c.requestContext(ctx)
	defer cancel()
	date := time.Now().UTC().Format(http.TimeFormat)
	contentMD5 := ""
	if method == http.MethodPost {
		digest := md5.Sum(body)
		contentMD5 = base64.StdEncoding.EncodeToString(digest[:])
	}
	canonicalQuery := "uploadId=" + signedQuery.Get("uploadId")
	if part := signedQuery.Get("partNumber"); part != "" {
		canonicalQuery = "partNumber=" + part + "&" + canonicalQuery
	}
	callbackHeader := ""
	if callback != "" {
		callbackHeader = "x-oss-callback:" + callback + "\n"
	}
	meta := fmt.Sprintf("%s\n%s\n%s\n%s\n%sx-oss-date:%s\nx-oss-user-agent:%s\n/%s/%s?%s",
		method, contentMD5, contentType, date, callbackHeader, date, ossAgent, session.Bucket, session.ObjectKey, canonicalQuery)
	var signed struct {
		Key string `json:"auth_key"`
	}
	_, err := c.uploadCall(ctx, "/file/upload/auth", map[string]string{
		"auth_info": auth.info, "auth_meta": meta, "task_id": session.TaskID,
	}, &signed)
	if err != nil {
		return nil, nil, err
	}
	if signed.Key == "" {
		return nil, nil, ErrInvalidResponse
	}
	endpoint := &url.URL{Scheme: "https", Host: session.Bucket + "." + session.StorageHost,
		Path: "/" + session.ObjectKey, RawQuery: strings.ReplaceAll(query.Encode(), "+", "%20")}
	req, err := http.NewRequestWithContext(ctx, method, endpoint.String(), bytes.NewReader(body))
	if err != nil {
		return nil, nil, ErrInvalidResponse
	}
	req.Header.Set("Authorization", signed.Key)
	req.Header.Set("Content-Type", contentType)
	req.Header.Set("Referer", referer)
	req.Header.Set("x-oss-date", date)
	req.Header.Set("x-oss-user-agent", ossAgent)
	if contentMD5 != "" {
		req.Header.Set("Content-MD5", contentMD5)
	}
	if callback != "" {
		req.Header.Set("x-oss-callback", callback)
	}
	response, err := c.http.Do(req)
	if err != nil {
		return nil, nil, transportError(err)
	}
	data, err := readBody(response, 1<<20)
	if err != nil {
		return nil, nil, err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, nil, parseStorageError(response.StatusCode, data, response.Header)
	}
	return data, response.Header, nil
}

func parseStorageError(status int, data []byte, header http.Header) *StorageError {
	var body struct {
		XMLName   xml.Name `xml:"Error"`
		Code      string   `xml:"Code"`
		RequestID string   `xml:"RequestId"`
	}
	parsed := xml.Unmarshal(data, &body) == nil
	if status >= 200 && status < 300 && !parsed {
		return nil
	}
	requestID := header.Get("x-oss-request-id")
	if requestID == "" {
		requestID = body.RequestID
	}
	return &StorageError{Status: status, Code: body.Code, RequestID: requestID}
}

func validHex(text string, length int) bool {
	if len(text) != length {
		return false
	}
	for _, b := range []byte(text) {
		if (b < '0' || b > '9') && (b < 'a' || b > 'f') && (b < 'A' || b > 'F') {
			return false
		}
	}
	return true
}

func unquoteETag(value string) string {
	if len(value) >= 2 && value[0] == '"' && value[len(value)-1] == '"' {
		return value[1 : len(value)-1]
	}
	return value
}
