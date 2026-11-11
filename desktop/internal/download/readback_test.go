package download

import (
	"bytes"
	"context"
	"crypto/sha256"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func TestReadbackRefreshesExpiredLinkWithoutHashingRangeTwice(t *testing.T) {
	data := bytes.Repeat([]byte("校验"), (256<<10)/6+1)
	const firstRange = "bytes=0-262143"
	lastRange := fmt.Sprintf("bytes=262144-%d", len(data)-1)
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		step := requests.Add(1)
		switch step {
		case 1:
			if r.URL.Path != "/first" || r.Header.Get("Range") != firstRange {
				t.Errorf("第一个范围: %s %s", r.URL.Path, r.Header.Get("Range"))
			}
		case 2:
			if r.URL.Path != "/first" || r.Header.Get("Range") != lastRange {
				t.Errorf("过期请求: %s %s", r.URL.Path, r.Header.Get("Range"))
			}
			w.WriteHeader(http.StatusForbidden)
			return
		case 3:
			if r.URL.Path != "/fresh" || r.Header.Get("Range") != lastRange {
				t.Errorf("刷新后请求: %s %s", r.URL.Path, r.Header.Get("Range"))
			}
		default:
			t.Errorf("多余的回读请求: %s", r.Header.Get("Range"))
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		ranged(t, w, r, data)
	}))
	defer server.Close()

	var resolved int
	var progress int64
	got, err := ReadbackSHA256(t.Context(), server.Client(), func(context.Context) (Link, error) {
		resolved++
		if resolved == 1 {
			return Link{URL: server.URL + "/first"}, nil
		}
		return Link{URL: server.URL + "/fresh"}, nil
	}, int64(len(data)), func(context.Context, int) error { return nil }, func(n int64) { progress = n })
	if err != nil || got != fmt.Sprintf("%x", sha256.Sum256(data)) || resolved != 2 || requests.Load() != 3 || progress != int64(len(data)) {
		t.Fatalf("摘要 %s，解析次数 %d，请求次数 %d，进度 %d，错误 %v", got, resolved, requests.Load(), progress, err)
	}
}
