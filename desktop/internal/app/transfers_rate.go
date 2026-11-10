package app

import (
	"context"
	"io"
	"net/http"
	"sync"
	"time"
)

// transferRate is shared by downloads and upload verification readbacks.
// Reservations charge bytes read from every HTTP attempt, including retries.
type transferRate struct {
	mu      sync.Mutex
	rate    int64
	next    time.Time
	changed chan struct{}
}

func newTransferRate(rate int64) *transferRate {
	return &transferRate{rate: rate, changed: make(chan struct{})}
}

func (r *transferRate) set(rate int64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.rate != rate {
		r.rate, r.next = rate, time.Time{}
		close(r.changed)
		r.changed = make(chan struct{})
	}
}

func (r *transferRate) readSize(maximum int) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.rate == 0 {
		return min(maximum, 32<<10)
	}
	// Keep each reservation near 125 ms at slow rates while avoiding large
	// buffered bursts at higher rates.
	return int(min(int64(maximum), max(1, r.rate/8), 32<<10))
}

func (r *transferRate) wait(ctx context.Context, size int) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		r.mu.Lock()
		if r.rate == 0 {
			r.mu.Unlock()
			return nil
		}
		now := time.Now()
		if r.next.Before(now) {
			r.next = now
		}
		r.next = r.next.Add(time.Duration(int64(size) * int64(time.Second) / r.rate))
		delay, changed := r.next.Sub(now), r.changed
		r.mu.Unlock()

		timer := time.NewTimer(delay)
		select {
		case <-timer.C:
			return ctx.Err()
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-changed:
			timer.Stop()
		}
	}
}

// waitUpload charges large parts in small increments so cancellation and
// configuration changes take effect while waiting for a shared budget.
func (r *transferRate) waitUpload(ctx context.Context, size int) error {
	for size > 0 {
		chunk := r.readSize(size)
		if err := r.wait(ctx, chunk); err != nil {
			return err
		}
		size -= chunk
	}
	return ctx.Err()
}

type transferRateTransport struct {
	base http.RoundTripper
	rate *transferRate
}

func (t transferRateTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	res, err := t.base.RoundTrip(req)
	if err != nil || res.Body == nil {
		return res, err
	}
	res.Body = &transferRateBody{ReadCloser: res.Body, ctx: req.Context(), rate: t.rate}
	return res, nil
}

type transferRateBody struct {
	io.ReadCloser
	ctx  context.Context
	rate *transferRate
}

func (r *transferRateBody) Read(p []byte) (int, error) {
	n, err := r.ReadCloser.Read(p[:r.rate.readSize(len(p))])
	if n != 0 {
		if limitErr := r.rate.wait(r.ctx, n); limitErr != nil {
			return 0, limitErr
		}
	}
	return n, err
}

func contentTransferClient(base *http.Client, rate *transferRate) *http.Client {
	if base == nil {
		base = http.DefaultClient
	}
	client := *base
	transport := client.Transport
	if transport == nil {
		transport = http.DefaultTransport
	}
	client.Transport = transferRateTransport{base: transport, rate: rate}
	// A whole-request timer would abort correct low-rate or large transfers.
	// Worker cancellation and the underlying transport own network timeouts.
	client.Timeout = 0
	return &client
}
