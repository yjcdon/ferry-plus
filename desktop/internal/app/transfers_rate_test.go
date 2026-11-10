package app

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

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
