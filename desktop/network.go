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

func (t *businessTransport) configure(settings platform.ProxySettings, password string) {
	if t.transport.Load() != nil && reflect.DeepEqual(t.settings, settings) && t.password == password {
		return
	}
	previous := t.transport.Swap(platform.NewTransport(settings, password))
	t.settings, t.password = settings, password
	if previous != nil {
		previous.CloseIdleConnections()
	}
}

func (t *businessTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	return t.transport.Load().RoundTrip(r)
}

func (t *businessTransport) CloseIdleConnections() {
	t.transport.Load().CloseIdleConnections()
}
