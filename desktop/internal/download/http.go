package download

import (
	"context"
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

var errRemoteChanged = errors.New("远端文件内容已变化，请重新添加任务")
var errRangeUnsupported = errors.New("远端不支持断点续传，已有下载字节已保留。请重新添加任务以重新下载")

type entity struct {
	ETag         string `json:"etag,omitempty"`
	LastModified string `json:"lastModified,omitempty"`
}

func responseEntity(response *http.Response) entity {
	return entity{ETag: response.Header.Get("ETag"), LastModified: response.Header.Get("Last-Modified")}
}

func (e entity) matches(other entity) bool {
	if e.ETag != "" {
		return other.ETag == "" || e.ETag == other.ETag
	}
	return e.LastModified == "" || other.LastModified == "" || e.LastModified == other.LastModified
}

func (e *entity) merge(other entity) {
	if e.ETag == "" {
		e.ETag = other.ETag
	}
	if e.LastModified == "" {
		e.LastModified = other.LastModified
	}
}

func (e entity) ifRange() string {
	if e.ETag != "" && !strings.HasPrefix(e.ETag, "W/") {
		return e.ETag
	}
	return e.LastModified
}

// One resolved link is shared by a file's connections. Stale responses only
// invalidate the same link that produced them, even if another worker refreshed.
type linkSource struct {
	resolve Resolve
	client  *http.Client
	mu      sync.Mutex
	link    *Link
}

func (s *linkSource) resolved(ctx context.Context) (*Link, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.link == nil {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		link, err := s.resolve(ctx)
		if err != nil {
			return nil, fmt.Errorf("获取下载地址: %w", err)
		}
		link.Headers = link.Headers.Clone()
		s.link = &link
	}
	return s.link, nil
}

func (s *linkSource) invalidate(link *Link) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.link == link {
		s.link = nil
	}
}

func (s *linkSource) get(ctx context.Context, start, end, size int64, previous entity) (*http.Response, error) {
	for attempt := 0; ; attempt++ {
		link, err := s.resolved(ctx)
		if err != nil {
			return nil, err
		}
		response, err := s.request(ctx, link, start, end, size, previous)
		if err == nil {
			return response, nil
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		var failure *responseFailure
		if !errors.As(err, &failure) || attempt >= 2 {
			return nil, err
		}
		switch failure.status {
		case 401, 403, 404, 410, 416:
			s.invalidate(link)
		case 429, 500, 502, 503, 504, 509:
			delay := time.Duration(attempt+1) * time.Second
			if failure.status == 429 || failure.status == 509 {
				delay *= 10
			}
			timer := time.NewTimer(delay)
			select {
			case <-timer.C:
			case <-ctx.Done():
				timer.Stop()
				return nil, ctx.Err()
			}
		default:
			return nil, err
		}
	}
}

type responseFailure struct{ status int }

func (f *responseFailure) Error() string {
	return fmt.Sprintf("下载请求失败，HTTP %d", f.status)
}

func (s *linkSource) request(ctx context.Context, link *Link, start, end, size int64, previous entity) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, link.URL, nil)
	if err != nil {
		return nil, errors.New("下载地址格式无效")
	}
	if req.URL.Host == "" || req.URL.Scheme != "http" && req.URL.Scheme != "https" {
		return nil, errors.New("下载地址必须是 HTTP 或 HTTPS")
	}
	for name, values := range link.Headers {
		req.Header[http.CanonicalHeaderKey(name)] = values
	}
	req.Header.Set("Accept-Encoding", "identity")
	req.Header.Del("Range")
	req.Header.Del("If-Range")
	if size > 0 {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, end-1))
		if value := previous.ifRange(); value != "" {
			req.Header.Set("If-Range", value)
		}
	}
	response, err := s.client.Do(req)
	if err != nil {
		var requestErr *url.Error
		if errors.As(err, &requestErr) {
			err = requestErr.Err // Do not expose signed URLs in UI or logs.
		}
		return nil, fmt.Errorf("请求下载内容: %w", err)
	}
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
		response.Body.Close()
		return nil, &responseFailure{status: response.StatusCode}
	}
	if response.Uncompressed || !identityEncoding(response.Header.Get("Content-Encoding")) {
		response.Body.Close()
		return nil, errors.New("下载响应经过内容编码，无法校验原始字节")
	}
	return response, nil
}

func (s *linkSource) fetchRange(ctx context.Context, start, end, size int64, previous entity) ([]byte, entity, error) {
	response, err := s.get(ctx, start, end, size, previous)
	if err != nil {
		return nil, entity{}, err
	}
	return rangeData(response, start, end, size)
}

func rangeData(response *http.Response, start, end, size int64) ([]byte, entity, error) {
	defer response.Body.Close()
	if response.StatusCode == http.StatusOK {
		if response.ContentLength == size {
			return nil, entity{}, errRangeUnsupported
		}
		return nil, entity{}, errors.New("分片下载响应忽略请求范围")
	}
	if err := validateRange(response, start, end, size); err != nil {
		return nil, entity{}, err
	}
	info := responseEntity(response)
	length := end - start
	data := make([]byte, length)
	if _, err := io.ReadFull(response.Body, data); err != nil {
		return nil, entity{}, fmt.Errorf("下载分片响应体长度不足: %w", err)
	}
	if err := expectEOF(response.Body); err != nil {
		return nil, entity{}, err
	}
	return data, info, nil
}

func validateRange(response *http.Response, start, end, size int64) error {
	if response.StatusCode != http.StatusPartialContent || start >= end ||
		!matchesContentRange(response.Header.Get("Content-Range"), start, end-1, size) {
		return errors.New("下载 Content-Range 与请求范围或文件大小不一致")
	}
	length := end - start
	if response.ContentLength != -1 && response.ContentLength != length {
		return errors.New("下载 Content-Length 与请求范围不一致")
	}
	return nil
}

func identityEncoding(value string) bool {
	value = strings.TrimSpace(value)
	return value == "" || strings.EqualFold(value, "identity")
}

func expectEOF(reader io.Reader) error {
	var extra [1]byte
	if _, err := io.ReadFull(reader, extra[:]); errors.Is(err, io.EOF) {
		return nil
	} else if err != nil {
		return fmt.Errorf("读取下载响应结尾: %w", err)
	}
	return errors.New("下载响应体超出预期长度")
}

func matchesContentRange(header string, start, last, size int64) bool {
	fields := strings.Fields(header)
	if len(fields) != 2 || !strings.EqualFold(fields[0], "bytes") {
		return false
	}
	ranges, total, ok := strings.Cut(fields[1], "/")
	if !ok {
		return false
	}
	lower, upper, ok := strings.Cut(ranges, "-")
	if !ok {
		return false
	}
	return matchesNumber(lower, start) && matchesNumber(upper, last) && matchesNumber(total, size)
}

func matchesNumber(value string, expected int64) bool {
	actual, err := strconv.ParseUint(value, 10, 63)
	return err == nil && actual == uint64(expected)
}

func redirectClient(base *http.Client) *http.Client {
	if base == nil {
		base = http.DefaultClient
	}
	client := *base
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if base.CheckRedirect != nil {
			if err := base.CheckRedirect(req, via); err != nil {
				return err
			}
		} else if len(via) >= 10 {
			return errors.New("下载地址重定向次数过多")
		}
		original := via[0]
		for _, field := range []string{"Range", "If-Range", "Accept-Encoding"} {
			if value := original.Header.Get(field); value != "" {
				req.Header.Set(field, value)
			}
		}
		originalHost := strings.EqualFold(original.URL.Hostname(), req.URL.Hostname()) &&
			(original.URL.Scheme != "https" || req.URL.Scheme == "https")
		for _, field := range []string{"Cookie", "Authorization", "Proxy-Authorization"} {
			if !originalHost {
				req.Header.Del(field)
			} else if values := original.Header.Values(field); len(values) > 0 && len(req.Header.Values(field)) == 0 {
				// Go drops these permanently after a cross-host redirect. Swift
				// allows them again if a later hop returns to the original host.
				req.Header[field] = append([]string(nil), values...)
			}
		}
		// Keep the provider-supplied Referer. Go's automatic one can contain
		// a signed download URL and must not be forwarded between hosts.
		if explicit := original.Header.Get("Referer"); explicit != "" {
			req.Header.Set("Referer", explicit)
		} else {
			req.Header.Del("Referer")
		}
		return nil
	}
	return &client
}
