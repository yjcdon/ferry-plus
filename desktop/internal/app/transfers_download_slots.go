package app

import "context"

// Download slots are shared across all batches and guarded by Transfers.mu.
type downloadSlots struct {
	files       int
	connections int
	changed     chan struct{}
}

func (t *Transfers) takeDownloadSlot(ctx context.Context, provider Provider) (int, func(), error) {
	for {
		if err := ctx.Err(); err != nil {
			return 0, nil, err
		}
		t.mu.Lock()
		connections := t.config.BaiduConnections
		if provider == Quark {
			connections = t.config.QuarkConnections
		}
		if t.downloadSlots.files < t.config.DownloadFiles &&
			t.downloadSlots.connections+connections <= TotalDownloadConnections {
			t.downloadSlots.files++
			t.downloadSlots.connections += connections
			t.mu.Unlock()
			return connections, func() {
				t.mu.Lock()
				t.downloadSlots.files--
				t.downloadSlots.connections -= connections
				t.signalDownloadSlotsLocked()
				t.mu.Unlock()
			}, nil
		}
		if t.downloadSlots.changed == nil {
			t.downloadSlots.changed = make(chan struct{})
		}
		changed := t.downloadSlots.changed
		t.mu.Unlock()
		select {
		case <-changed:
		case <-ctx.Done():
			return 0, nil, ctx.Err()
		}
	}
}

func (t *Transfers) signalDownloadSlotsLocked() {
	if t.downloadSlots.changed != nil {
		close(t.downloadSlots.changed)
		t.downloadSlots.changed = nil
	}
}
