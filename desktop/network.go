package main

import (
	"net/http"
	"reflect"
	"sync/atomic"

	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

// businessTransport lets existing provider clients use a saved proxy change
// for new requests. Official login pages keep the web engine's system proxy.
type businessTransport struct {
	transport atomic.Pointer[http.Transport]
	settings  platform.ProxySettings
	password  string
}

// proxyChange tracks the latest requested settings on the UI thread and
// returns the transport swap to run once active transfers have stopped.
func (t *businessTransport) proxyChange(settings platform.ProxySettings, password string) func() {
	if reflect.DeepEqual(t.settings, settings) && t.password == password && t.transport.Load() != nil {
		return nil
	}
	t.settings, t.password = settings, password
	return func() {
		previous := t.transport.Swap(platform.NewTransport(settings, password))
		if previous != nil {
			previous.CloseIdleConnections()
		}
	}
}

func (t *businessTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	return t.transport.Load().RoundTrip(r)
}

func (t *businessTransport) CloseIdleConnections() {
	t.transport.Load().CloseIdleConnections()
}
