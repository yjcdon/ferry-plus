package baidu

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
)

const UploadPartSize = 4 * 1024 * 1024
const RapidProofLength = 256 * 1024

var (
	ErrInvalidUploadPlan       = errors.New("百度上传文件清单、路径或分片信息无效。")
	ErrUploadSourceChanged     = errors.New("本地分片内容与上传前的校验值不同，请按新版本重新上传。")
	ErrInvalidPartReceipt      = errors.New("百度返回的上传分片校验值不一致。")
	ErrUnresolvedInstantUpload = errors.New("百度返回秒传结果，但未提供可核对的文件身份，需要查询确认。")
	ErrUploadAccountChanged    = errors.New("百度账号已变化，不能继续原上传会话的快速上传。")
)

// UploadSession is the recoverable pre-upload receipt. It contains no credentials.
type UploadSession struct {
	UploadID     string   `json:"uploadID"`
	Path         string   `json:"path"`
	Size         int64    `json:"size"`
	BlockMD5s    []string `json:"blockMD5s"`
	PendingParts []int    `json:"pendingParts"`
}

// UnmarshalJSON validates a recovered upload session before it can send parts.
func (s *UploadSession) UnmarshalJSON(data []byte) error {
	type savedSession UploadSession
	var recovered savedSession
	if err := json.Unmarshal(data, &recovered); err != nil {
		return err
	}
	session := UploadSession(recovered)
	if err := session.validate(); err != nil {
		return err
	}
	session.BlockMD5s = uploadHashes(session.BlockMD5s)
	*s = session
	return nil
}

type UploadPreparation struct {
	Session *UploadSession
	Instant *Entry
}

type UploadPartReceipt struct {
	Index int    `json:"index"`
	Size  int    `json:"size"`
	MD5   string `json:"md5"`
}

func (s UploadSession) validate() error {
	if s.UploadID == "" || !validPath(s.Path) || s.Size < 0 {
		return ErrInvalidUploadPlan
	}
	count := s.Size / UploadPartSize
	if s.Size%UploadPartSize != 0 {
		count++
	}
	if int64(len(s.BlockMD5s)) != max(count, 1) {
		return ErrInvalidUploadPlan
	}
	for _, hash := range s.BlockMD5s {
		if !validMD5(hash) {
			return ErrInvalidUploadPlan
		}
	}
	seen := map[int]bool{}
	for _, idx := range s.PendingParts {
		if idx < 0 || idx >= len(s.BlockMD5s) || seen[idx] {
			return ErrInvalidUploadPlan
		}
		seen[idx] = true
	}
	return nil
}

func validMD5(s string) bool {
	if len(s) != 32 {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil
}

func (s UploadSession) partLength(index int) int64 {
	return min(UploadPartSize, s.Size-int64(index)*UploadPartSize)
}

func uploadHashes(hashes []string) []string {
	normalized := make([]string, len(hashes))
	for i, hash := range hashes {
		normalized[i] = strings.ToLower(hash)
	}
	return normalized
}

// PrepareUpload asks Baidu which parts it needs, or returns a precise instant
// upload identity that the caller must verify by reading the full content.
func (c *Client) PrepareUpload(ctx context.Context, file string, size int64, hashes []string, contentMD5, sliceMD5 string) (UploadPreparation, error) {
	plan := UploadSession{UploadID: "prepare", Path: file, Size: size, BlockMD5s: uploadHashes(hashes)}
	if err := plan.validate(); err != nil || !validMD5(contentMD5) || !validMD5(sliceMD5) {
		return UploadPreparation{}, ErrInvalidUploadPlan
	}
	blockList, _ := json.Marshal(plan.BlockMD5s)
	j, err := c.uploadForm(ctx, "precreate", url.Values{"path": {file}, "size": {decimal(size)}, "isdir": {"0"}, "block_list": {string(blockList)},
		"autoinit": {"1"}, "rtype": {"0"}, "content-md5": {strings.ToLower(contentMD5)}, "slice-md5": {strings.ToLower(sliceMD5)}})
	if err != nil {
		return UploadPreparation{}, err
	}
	switch num(j["return_type"]) {
	case 1:
		plan.UploadID = str(j["uploadid"])
		raw := list(j["block_list"])
		if plan.UploadID == "" || raw == nil {
			return UploadPreparation{}, ErrInvalidResponse
		}
		plan.PendingParts = make([]int, len(raw))
		for i, v := range raw {
			index, err := strconv.Atoi(str(v))
			if err != nil {
				return UploadPreparation{}, ErrInvalidResponse
			}
			plan.PendingParts[i] = index
		}
		if err := plan.validate(); err != nil {
			return UploadPreparation{}, err
		}
		return UploadPreparation{Session: &plan}, nil
	case 2:
		if _, ok := integer(j["fs_id"]); !ok {
			return UploadPreparation{}, ErrUnresolvedInstantUpload
		}
		entry, err := uploadedEntry(j, file, size)
		if err != nil {
			return UploadPreparation{}, err
		}
		return UploadPreparation{Instant: &entry}, nil
	default:
		return UploadPreparation{}, ErrInvalidResponse
	}
}

// UploadPart sends one bounded block after checking its source digest and verifies
// the server's receipt. The multipart body reads the original block directly.
func (c *Client) UploadPart(ctx context.Context, data []byte, index int, upload UploadSession) (UploadPartReceipt, error) {
	if index < 0 || index >= len(upload.BlockMD5s) || int64(len(data)) != upload.partLength(index) {
		return UploadPartReceipt{}, ErrInvalidUploadPlan
	}
	expected := strings.ToLower(upload.BlockMD5s[index])
	if fmt.Sprintf("%x", md5.Sum(data)) != expected {
		return UploadPartReceipt{}, ErrUploadSourceChanged
	}

	var multipartHead bytes.Buffer
	form := multipart.NewWriter(&multipartHead)
	if _, err := form.CreateFormFile("file", "part.bin"); err != nil {
		return UploadPartReceipt{}, err
	}
	tail := "\r\n--" + form.Boundary() + "--\r\n"
	body := io.MultiReader(bytes.NewReader(multipartHead.Bytes()), bytes.NewReader(data), strings.NewReader(tail))
	address := endpoint("https://d.pcs.baidu.com/rest/2.0/pcs/superfile2", url.Values{"app_id": {panID}, "method": {"upload"},
		"type": {"tmpfile"}, "path": {upload.Path}, "uploadid": {upload.UploadID}, "partseq": {strconv.Itoa(index)}})
	r := request{method: http.MethodPost, url: address, ua: netdiskUA, cookies: c.credential.Cookies,
		headers: http.Header{"Referer": {pan + "/"}, "Content-Type": {form.FormDataContentType()}}, body: body, length: int64(multipartHead.Len() + len(data) + len(tail))}
	j, err := c.checked(ctx, r, "error_code", "")
	if err != nil {
		return UploadPartReceipt{}, err
	}
	if strings.ToLower(str(j["md5"])) != expected {
		return UploadPartReceipt{}, ErrInvalidPartReceipt
	}
	return UploadPartReceipt{index, len(data), expected}, nil
}

// CompleteUpload confirms all required receipts before issuing the merge.
// The caller persists its submit intent before calling this method.
func (c *Client) CompleteUpload(ctx context.Context, upload UploadSession, receipts []UploadPartReceipt) (Entry, error) {
	if err := upload.validate(); err != nil || len(receipts) != len(upload.PendingParts) {
		return Entry{}, ErrInvalidUploadPlan
	}
	pending := make(map[int]bool, len(upload.PendingParts))
	for _, idx := range upload.PendingParts {
		pending[idx] = true
	}
	for _, receipt := range receipts {
		idx := receipt.Index
		if !pending[idx] || !strings.EqualFold(receipt.MD5, upload.BlockMD5s[idx]) || int64(receipt.Size) != upload.partLength(idx) {
			return Entry{}, ErrInvalidUploadPlan
		}
		delete(pending, idx)
	}
	hashes, _ := json.Marshal(uploadHashes(upload.BlockMD5s))
	j, err := c.uploadForm(ctx, "create", url.Values{"path": {upload.Path}, "size": {decimal(upload.Size)}, "isdir": {"0"},
		"uploadid": {upload.UploadID}, "block_list": {string(hashes)}, "rtype": {"0"}})
	if err != nil {
		return Entry{}, err
	}
	return uploadedEntry(j, upload.Path, upload.Size)
}

func (c *Client) uploadForm(ctx context.Context, op string, fields url.Values) (object, error) {
	token, err := c.bdstoken(ctx)
	if err != nil {
		return nil, err
	}
	address := endpoint(pan+"/api/"+op, url.Values{"app_id": {panID}, "clienttype": {"0"}, "web": {"1"}, "bdstoken": {token}})
	r := request{url: address, ua: netdiskUA, cookies: c.credential.Cookies, headers: http.Header{"Referer": {pan + "/"}}}.form(fields)
	j, err := c.checked(ctx, r, "errno", "")
	if err != nil {
		return nil, err
	}
	if code, ok := integer(j["errno"]); !ok || code != 0 {
		return nil, ErrInvalidResponse
	}
	return j, nil
}

func uploadedEntry(j object, file string, size int64) (Entry, error) {
	id, idOK := integer(j["fs_id"])
	bytes, bytesOK := integer(j["size"])
	directory, dirOK := integer(j["isdir"])
	if !idOK || id <= 0 || !bytesOK || bytes != size || !dirOK || directory != 0 || str(j["path"]) != file {
		return Entry{}, ErrInvalidResponse
	}
	return Entry{FSID: id, Name: path.Base(file), Path: file, Size: size}, nil
}

// RapidUpload sends the exact 256 KiB source challenge for the account and
// session. Nil entry with nil error means the provider explicitly did not match.
func (c *Client) RapidUpload(ctx context.Context, upload UploadSession, expectedUK int64, contentMD5, sliceMD5 string,
	onSubmitting func(int) error, readProof func(offset int64, length int) ([]byte, error)) (*Entry, error) {
	if err := upload.validate(); err != nil || expectedUK <= 0 || upload.Size <= RapidProofLength || !validMD5(contentMD5) || !validMD5(sliceMD5) {
		return nil, ErrInvalidUploadPlan
	}
	uk, _, err := c.userInfo(ctx)
	if err != nil {
		return nil, err
	}
	if uk != expectedUK {
		return nil, ErrUploadAccountChanged
	}
	token, err := c.bdstoken(ctx)
	if err != nil {
		return nil, err
	}
	now := c.now().Unix()
	obfuscatedContent := obfuscatedMD5(contentMD5)
	digest := md5Text(decimal(uk) + obfuscatedContent + decimal(now))
	first, _ := strconv.ParseUint(digest[:8], 16, 64)
	offset := int64(first % uint64(upload.Size-RapidProofLength+1))
	proof, err := readProof(offset, RapidProofLength)
	if err != nil {
		return nil, err
	}
	if len(proof) != RapidProofLength {
		return nil, ErrInvalidUploadPlan
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	parent := path.Dir(upload.Path)
	target := parent
	if parent != "/" {
		target += "/"
	}
	fields := url.Values{"uploadid": {upload.UploadID}, "path": {upload.Path}, "target_path": {target}, "content-length": {decimal(upload.Size)},
		"content-md5": {obfuscatedContent}, "slice-md5": {obfuscatedMD5(sliceMD5)}, "data_time": {decimal(now)}, "data_offset": {decimal(offset)},
		"data_content": {base64.StdEncoding.EncodeToString(proof)}}
	address := endpoint(pan+"/api/rapidupload", url.Values{"rtype": {"1"}, "app_id": {panID}, "channel": {"chunlei"}, "web": {"1"}, "clienttype": {"0"}, "bdstoken": {token}})
	r := request{url: address, ua: netdiskUA, cookies: c.credential.Cookies, headers: http.Header{"Referer": {pan + "/"}}}.form(fields)
	if err := onSubmitting(int(r.length)); err != nil {
		return nil, err
	}
	j, reply, err := c.json(ctx, r)
	if err != nil {
		return nil, err
	}
	if reply.status < 200 || reply.status >= 300 {
		return nil, HTTPError(reply.status)
	}
	code, ok := integer(j["errno"])
	if !ok {
		return nil, ErrInvalidResponse
	}
	if code == 404 {
		return nil, nil
	}
	if code != 0 {
		return nil, apiError(code, message(j), "")
	}
	info := obj(j["info"])
	actual := str(info["path"])
	if !validPath(actual) || path.Dir(actual) != parent {
		return nil, ErrUnresolvedInstantUpload
	}
	entry, err := uploadedEntry(info, actual, upload.Size)
	if err != nil {
		return nil, ErrUnresolvedInstantUpload
	}
	return &entry, nil
}

func obfuscatedMD5(hash string) string {
	hash = strings.ToLower(hash)
	reordered := hash[8:16] + hash[:8] + hash[24:] + hash[16:24]
	const alphabet = "0123456789abcdef"
	var encoded [32]byte
	for i, r := range reordered {
		value := byte(strings.IndexRune(alphabet, r)) ^ byte(i&15)
		encoded[i] = alphabet[value]
		if i == 9 {
			encoded[i] = 'g' + value
		}
	}
	return string(encoded[:])
}
