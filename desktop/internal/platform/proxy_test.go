package platform

import (
	"bytes"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestSOCKS5AuthenticationRejection(t *testing.T) {
	server, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()

	password := " password:含空格 "
	auth := make(chan []byte, 1)
	go func() {
		conn, err := server.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(3 * time.Second))
		hello := make([]byte, 4)
		if _, err := io.ReadFull(conn, hello); err != nil || !bytes.Equal(hello, []byte{5, 2, 0, 2}) {
			return
		}
		if _, err := conn.Write([]byte{5, 2}); err != nil {
			return
		}
		credentials := make([]byte, 3+len("ferry")+len(password))
		if _, err := io.ReadFull(conn, credentials); err != nil {
			return
		}
		auth <- credentials
		conn.Write([]byte{1, 1}) // Reject authentication.
	}()

	port := server.Addr().(*net.TCPAddr).Port
	transport := NewTransport(ProxySettings{
		Mode: ProxySOCKS5, Host: " 127.0.0.1 ", Port: &port, Username: " ferry ",
	}, password)
	defer transport.CloseIdleConnections()
	client := http.Client{Transport: transport, Timeout: 3 * time.Second}
	_, err = client.Get("http://ferry.test/")
	if err == nil || !strings.Contains(err.Error(), "username/password authentication failed") {
		t.Fatalf("expected a SOCKS5 authentication error, got %v", err)
	}
	select {
	case received := <-auth:
		want := append([]byte{1, 5}, []byte("ferry")...)
		want = append(want, byte(len(password)))
		want = append(want, []byte(password)...)
		if !bytes.Equal(received, want) {
			t.Fatal("SOCKS5 authentication changed the credentials")
		}
	default:
		t.Fatal("SOCKS5 proxy did not receive authentication")
	}
}

func TestProxyProblem(t *testing.T) {
	settings := ProxySettings{Mode: ProxySOCKS5}
	zero := 0
	port := 1080
	for _, test := range []struct {
		host     string
		port     *int
		username string
		want     string
	}{
		{"", nil, "", "请填写代理服务器。"},
		{"127.0.0.1", nil, "", "请填写代理端口。"},
		{"127.0.0.1", &zero, "", "端口需要在 1–65535 之间。"},
		{"127.0.0.1", &port, "ferry", "用户名和密码需要同时填写。"},
	} {
		settings.Host, settings.Port, settings.Username = test.host, test.port, test.username
		if err := settings.Problem(""); err == nil || err.Error() != test.want {
			t.Errorf("expected %q, got %v", test.want, err)
		}
	}
}
