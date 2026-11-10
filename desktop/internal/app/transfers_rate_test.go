package app

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func contentClientWithIdle(base *http.Client, rate int64, idle time.Duration) *http.Client {
	client := contentTransferClient(base, newTransferRate(rate))
	transport := client.Transport.(transferRateTransport)
	transport.idle = idle
	client.Transport = transport
	return client
}

func TestTransferResponseHeadersHaveIdleTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, req *http.Request) {
		<-req.Context().Done()
	}))
	defer server.Close()
	client := contentClientWithIdle(server.Client(), 0, 100*time.Millisecond)
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, server.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	res, err := client.Do(req)
	if res != nil {
		res.Body.Close()
	}
	if !errors.Is(err, errContentIdle) {
		t.Fatalf("等待响应头没有触发传输超时: %v", err)
	}
}

func TestTransferBodyIdleAndUserCancellation(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		_, _ = io.WriteString(w, "abc")
		w.(http.Flusher).Flush()
		<-req.Context().Done()
	}))
	defer server.Close()
	client := contentClientWithIdle(server.Client(), 0, 100*time.Millisecond)
	for _, test := range []struct {
		name string
		want error
	}{
		{"读取超时", errContentIdle},
		{"用户取消", context.Canceled},
	} {
		t.Run(test.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
			defer cancel()
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, server.URL, nil)
			if err != nil {
				t.Fatal(err)
			}
			res, err := client.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer res.Body.Close()
			var first [3]byte
			if _, err := io.ReadFull(res.Body, first[:]); err != nil || string(first[:]) != "abc" {
				t.Fatalf("首段数据不符: %q, %v", first, err)
			}
			if test.want == context.Canceled {
				cancel()
			}
			if _, err := res.Body.Read(first[:]); !errors.Is(err, test.want) {
				t.Fatalf("后续读取返回 %v，预期 %v", err, test.want)
			}
		})
	}
}

func TestTransferLimiterWaitDoesNotCountAsIdle(t *testing.T) {
	base := &http.Client{Transport: directoryTransport(func(_ *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, ContentLength: 1, Body: io.NopCloser(strings.NewReader("a"))}, nil
	})}
	client := contentClientWithIdle(base, 8, 30*time.Millisecond)
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://example.test/", nil)
	if err != nil {
		t.Fatal(err)
	}
	res, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	start := time.Now()
	body, err := io.ReadAll(res.Body)
	if err != nil || string(body) != "a" || time.Since(start) < 100*time.Millisecond {
		t.Fatalf("限速等待不应触发读取超时: %q, %v", body, err)
	}
}

func TestSharedTransferRateAndCancellation(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "12345678")
	}))
	defer server.Close()
	rate := newTransferRate(32)
	base := server.Client()
	base.Timeout = 10 * time.Millisecond
	client := contentTransferClient(base, rate)
	if base.Timeout != 10*time.Millisecond || client.Timeout != 0 {
		t.Fatal("只应清除内容客户端的整请求超时")
	}

	start := time.Now()
	results := make(chan error, 2)
	for range 2 {
		go func() {
			req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, server.URL, nil)
			if err != nil {
				results <- err
				return
			}
			res, err := client.Do(req)
			if err != nil {
				results <- err
				return
			}
			defer res.Body.Close()
			body, err := io.ReadAll(res.Body)
			if err == nil && string(body) != "12345678" {
				err = errors.New("限速传输内容不一致")
			}
			results <- err
		}()
	}
	for range 2 {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	if elapsed := time.Since(start); elapsed < 400*time.Millisecond {
		t.Fatalf("两个请求没有共享限速预算: %s", elapsed)
	}

	rate.set(1)
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() { done <- rate.wait(ctx, 1) }()
	waitRateReservation(t, rate)
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("取消未中断限速等待: %v", err)
	}
}

func TestTransferRateChangeReleasesWaitingRead(t *testing.T) {
	rate := newTransferRate(1)
	done := make(chan error, 1)
	go func() { done <- rate.wait(t.Context(), 20) }()
	waitRateReservation(t, rate)
	rate.set(0)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("取消限速后旧的等待没有结束")
	}
}

func waitRateReservation(t *testing.T, rate *transferRate) {
	t.Helper()
	deadline := time.After(2 * time.Second)
	for {
		rate.mu.Lock()
		pending := !rate.next.IsZero()
		rate.mu.Unlock()
		if pending {
			return
		}
		select {
		case <-deadline:
			t.Fatal("读取未进入限速等待")
		case <-time.After(time.Millisecond):
		}
	}
}

func TestUploadPartsShareLiveRate(t *testing.T) {
	rate := newTransferRate(32)
	start := time.Now()
	done := make(chan error, 2)
	for range 2 {
		go func() { done <- rate.waitUpload(t.Context(), 8) }()
	}
	for range 2 {
		if err := <-done; err != nil {
			t.Fatal(err)
		}
	}
	if elapsed := time.Since(start); elapsed < 450*time.Millisecond {
		t.Fatalf("并发上传未共享限速预算: %s", elapsed)
	}
	rate.set(1)
	go func() { done <- rate.waitUpload(t.Context(), 100) }()
	waitRateReservation(t, rate)
	rate.set(0)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("关闭限速后上传分片仍在等待")
	}
}
