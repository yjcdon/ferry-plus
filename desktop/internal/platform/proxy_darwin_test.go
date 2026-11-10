package platform

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestMacProxyAutoConfiguration(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/x-ns-proxy-autoconfig")
		io.WriteString(w, `function FindProxyForURL(url, host) {
			if (host == "ferry.test") return "PROXY proxy.ferry.test:8080; DIRECT";
			return "DIRECT";
		}`)
	}))
	defer server.Close()

	api := appleProxy()
	makeURL := func(raw string) uintptr {
		t.Helper()
		value := []byte(raw)
		result := api.createURL(0, &value[0], len(value), cfUTF8, 0)
		if result == 0 {
			t.Fatalf("could not construct CFURL from %q", raw)
		}
		t.Cleanup(func() { api.release(result) })
		return result
	}
	script := makeURL(server.URL)
	target := makeURL("https://ferry.test/")
	entries, err := api.evaluatePAC(api.pacURL, script, target)
	if err != nil {
		t.Fatal(err)
	}
	defer api.release(entries)
	proxy, err := api.firstProxy(entries, 0)
	if err != nil || proxy == nil || proxy.String() != "http://proxy.ferry.test:8080" {
		t.Fatalf("unexpected PAC route %v, %v", proxy, err)
	}
}
