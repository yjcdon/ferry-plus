package download

import (
	"bytes"
	"context"
	"crypto/md5"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

type testRecords struct {
	mu          sync.Mutex
	values      map[string][]byte
	failPublish bool
}

func (r *testRecords) Read(key string, value any) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	data, ok := r.values[key]
	if !ok {
		return fs.ErrNotExist
	}
	return json.Unmarshal(data, value)
}

func (r *testRecords) Write(key string, value any) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if value.(checkpoint).Published && r.failPublish {
		r.failPublish = false
		return errors.New("保存发布回执失败")
	}
	data, err := json.Marshal(value)
	if err == nil {
		r.values[key] = data
	}
	return err
}

func (r *testRecords) Remove(key string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.values, key)
	return nil
}

func newTestRecords() *testRecords {
	return &testRecords{values: make(map[string][]byte)}
}

func testRequest(t *testing.T, data []byte) Request {
	t.Helper()
	return Request{
		ID: "file-1", Folder: platform.LocalReference{Path: t.TempDir()},
		RelativePath: "资料/文件.txt", Size: int64(len(data)), Connections: 4,
		ExpectedMD5: fmt.Sprintf("%x", md5.Sum(data)), ExpectedSHA256: fmt.Sprintf("%x", sha256.Sum256(data)),
	}
}

func resolver(address string) Resolve {
	return func(context.Context) (Link, error) { return Link{URL: address}, nil }
}

func ranged(t *testing.T, w http.ResponseWriter, r *http.Request, data []byte) {
	t.Helper()
	var start, last int
	if n, err := fmt.Sscanf(r.Header.Get("Range"), "bytes=%d-%d", &start, &last); err != nil ||
		n != 2 || start < 0 || last < start || last >= len(data) {
		t.Errorf("错误 Range %q", r.Header.Get("Range"))
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	w.Header().Set("ETag", `"v1"`)
	w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, last, len(data)))
	w.WriteHeader(http.StatusPartialContent)
	_, _ = w.Write(data[start : last+1])
}

func requireFile(t *testing.T, path string, want []byte) {
	t.Helper()
	actual, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(actual, want) {
		t.Fatalf("文件 %q 长度 %d，预期 %d，错误 %v", path, len(actual), len(want), err)
	}
}

func TestResumeAfterCancellation(t *testing.T) {
	data := bytes.Repeat([]byte("测试内容"), 75_000)
	req := testRequest(t, data)
	records := newTestRecords()
	var ignoreRange atomic.Bool
	var resumed atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if ignoreRange.Load() {
			w.Header().Set("ETag", `"v1"`)
			w.Header().Set("Content-Length", fmt.Sprint(len(data)))
			_, _ = w.Write(data)
			return
		}
		if resumed.Load() && (strings.HasPrefix(r.Header.Get("Range"), "bytes=0-") ||
			r.Header.Get("If-Range") != `"v1"`) {
			t.Errorf("恢复发出无效请求 Range=%q，If-Range=%q", r.Header.Get("Range"), r.Header.Get("If-Range"))
		}
		ranged(t, w, r, data)
	}))
	defer server.Close()

	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	_, err := newEngine(records, server.Client()).Run(ctx, req, resolver(server.URL), func(done, _ int64) {
		if done == segmentSize(req.Size) {
			cancel()
		}
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("暂停结果 = %v", err)
	}

	ignoreRange.Store(true)
	if _, err := newEngine(records, server.Client()).Run(t.Context(), req, resolver(server.URL), nil); !errors.Is(err, errRangeUnsupported) {
		t.Fatalf("服务端忽略恢复 Range 时应保留断点，结果 %v", err)
	}

	resumed.Store(true)
	ignoreRange.Store(false)
	result, err := newEngine(records, server.Client()).Run(t.Context(), req, resolver(server.URL), nil)
	if err != nil || !result.Verified {
		t.Fatalf("恢复结果 = %+v, %v", result, err)
	}
	requireFile(t, result.Path, data)
}

func TestMalformedRangeDoesNotPublish(t *testing.T) {
	const data = "hello"
	for _, fixture := range []struct {
		name        string
		rangeHeader string
		body        string
	}{
		{"偏移错误", "bytes 1-4/5", data},
		{"大小错误", "bytes 0-4/6", data},
		{"缺少长度", "bytes 0-4/*", data},
		{"响应体过长", "bytes 0-4/5", data + "!"},
		{"响应体截断", "bytes 0-4/5", data[:4]},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Range", fixture.rangeHeader)
				w.WriteHeader(http.StatusPartialContent)
				w.(http.Flusher).Flush() // Body is chunked and must also be checked.
				_, _ = fmt.Fprint(w, fixture.body)
			}))
			defer server.Close()
			req := testRequest(t, []byte(data))
			result, err := newEngine(newTestRecords(), server.Client()).Run(t.Context(), req, resolver(server.URL), nil)
			if err == nil || result.Path != "" {
				t.Fatalf("错误响应结果 = %+v, %v", result, err)
			}
			if _, err := os.Stat(filepath.Join(req.Folder.Path, "资料", "文件.txt")); !errors.Is(err, fs.ErrNotExist) {
				t.Fatalf("错误内容被发布: %v", err)
			}
		})
	}
}

func TestConcurrentSameNameKeepsBoth(t *testing.T) {
	data := []byte("hello")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ranged(t, w, r, data)
	}))
	defer server.Close()
	engine := newEngine(newTestRecords(), server.Client())
	base := testRequest(t, data)
	var group sync.WaitGroup
	for _, id := range []string{"first", "second"} {
		req := base
		req.ID = id
		group.Go(func() {
			result, err := engine.Run(t.Context(), req, resolver(server.URL), nil)
			if err != nil || !result.Verified {
				t.Errorf("同名下载 = %+v, %v", result, err)
			}
		})
	}
	group.Wait()
	for _, name := range []string{"文件.txt", "文件 (1).txt"} {
		requireFile(t, filepath.Join(base.Folder.Path, "资料", name), data)
	}
}

func TestPublicationReceiptRecoversBeforeAcknowledgement(t *testing.T) {
	data := []byte("hello")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ranged(t, w, r, data)
	}))
	defer server.Close()
	req := testRequest(t, data)
	records := newTestRecords()
	records.failPublish = true
	_, err := newEngine(records, server.Client()).Run(t.Context(), req, resolver(server.URL), nil)
	if err == nil {
		t.Fatal("回执失败时不能报告已完成")
	}
	engine := newEngine(records, server.Client())
	noNetwork := func(context.Context) (Link, error) { return Link{}, errors.New("恢复回执无需重新解析地址") }
	result, err := engine.Run(t.Context(), req, noNetwork, nil)
	if err != nil || filepath.Base(result.Path) != "文件.txt" {
		t.Fatalf("恢复回执 = %+v, %v", result, err)
	}
	requireFile(t, result.Path, data)
	repeated, err := engine.Run(t.Context(), req, noNetwork, nil)
	if err != nil || repeated.Path != result.Path {
		t.Fatalf("重复回执 = %+v, %v", repeated, err)
	}
	if err := engine.Acknowledge(req.ID); err != nil || len(records.values) != 0 {
		t.Fatalf("确认发布失败: %v", err)
	}
}

func TestRecoverDoesNotAdoptUnrelatedDestination(t *testing.T) {
	data := []byte("hello")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ranged(t, w, r, data)
	}))
	defer server.Close()
	req := testRequest(t, data)
	records := newTestRecords()
	records.failPublish = true
	_, err := newEngine(records, server.Client()).Run(t.Context(), req, resolver(server.URL), nil)
	if err == nil {
		t.Fatal("未写入回执时不能完成")
	}
	dir := filepath.Join(req.Folder.Path, "资料")
	final := filepath.Join(dir, "文件.txt")
	unrelated := []byte("other")
	replacement := filepath.Join(dir, "替换.txt")
	if err := os.WriteFile(replacement, unrelated, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(replacement, final); err != nil {
		t.Fatal(err)
	}
	result, err := newEngine(records, server.Client()).Run(t.Context(), req, resolver(server.URL), nil)
	if err == nil && result.Path == final {
		t.Fatal("不能把另一个同大小的文件误判为已完成")
	}
	requireFile(t, final, unrelated)
}

func TestIntegrityMismatchRetriesContent(t *testing.T) {
	data := []byte("hello")
	var corrected atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if corrected.Load() {
			ranged(t, w, r, data)
			return
		}
		ranged(t, w, r, []byte("wrong"))
	}))
	defer server.Close()
	req := testRequest(t, data)
	engine := newEngine(newTestRecords(), server.Client())
	if result, err := engine.Run(t.Context(), req, resolver(server.URL), nil); !errors.Is(err, ErrIntegrityMismatch) || result.Path != "" {
		t.Fatalf("校验错误结果 = %+v, %v", result, err)
	}
	corrected.Store(true)
	result, err := engine.Run(t.Context(), req, resolver(server.URL), nil)
	if err != nil || !result.Verified {
		t.Fatalf("重新下载结果 = %+v, %v", result, err)
	}
	requireFile(t, result.Path, data)
}

func TestExpiredLinkAndRedirect(t *testing.T) {
	data := []byte("hello")
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Cookie") != "" || r.Header.Get("Authorization") != "" ||
			r.Header.Get("X-Download") != "test" || r.Header.Get("Accept-Encoding") != "identity" ||
			r.Header.Get("Referer") != "https://pan.quark.cn/" {
			t.Errorf("跨主机重定向请求头不正确")
		}
		ranged(t, w, r, data)
	}))
	defer target.Close()
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/expired" {
			w.WriteHeader(http.StatusGone)
			return
		}
		if r.Header.Get("Cookie") == "" {
			t.Error("原始主机缺少下载 Cookie")
		}
		http.Redirect(w, r, strings.Replace(target.URL, "127.0.0.1", "localhost", 1), http.StatusFound)
	}))
	defer source.Close()
	var attempts int
	resolve := func(context.Context) (Link, error) {
		attempts++
		path := "/expired"
		if attempts == 2 {
			path = "/new"
		}
		return Link{URL: source.URL + path, Headers: http.Header{
			"Cookie": {"session=sample"}, "Authorization": {"sample"}, "X-Download": {"test"},
			"Referer": {"https://pan.quark.cn/"},
		}}, nil
	}
	req := testRequest(t, data)
	req.ExpectedMD5, req.ExpectedSHA256 = "", ""
	result, err := newEngine(newTestRecords(), source.Client()).Run(t.Context(), req, resolve, nil)
	if err != nil || attempts != 2 || result.Verified {
		t.Fatalf("刷新和重定向结果 = %+v, %v，解析次数 %d", result, err, attempts)
	}
	requireFile(t, result.Path, data)
}

func TestRedirectCredentialsReturnOnlyToOriginalHost(t *testing.T) {
	original := httptest.NewRequest(http.MethodGet, "https://original.test/download?token=sample", nil)
	original.Header.Set("Cookie", "session=sample")
	client := redirectClient(nil)
	for address, want := range map[string]string{
		"https://original.test/final":     "session=sample",
		"https://cdn.original.test/final": "",
		"http://original.test/final":      "",
	} {
		redirect := httptest.NewRequest(http.MethodGet, address, nil)
		redirect.Header.Set("Referer", original.URL.String())
		if err := client.CheckRedirect(redirect, []*http.Request{original}); err != nil ||
			redirect.Header.Get("Cookie") != want || redirect.Header.Get("Referer") != "" {
			t.Errorf("重定向 %s 的凭据范围不符，错误 %v", address, err)
		}
	}
}
