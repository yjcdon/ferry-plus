package app

import (
	"context"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"strings"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
	"github.com/yjcdon/ferry-drive/desktop/internal/quark"
)

type memoryCredentials struct {
	values                  map[string][]byte
	writeError, deleteError error
}

func (m *memoryCredentials) ReadCredential(name string) ([]byte, error) {
	value, ok := m.values[name]
	if !ok {
		return nil, fs.ErrNotExist
	}
	return value, nil
}

func (m *memoryCredentials) WriteCredential(name string, data []byte) error {
	if m.writeError != nil {
		return m.writeError
	}
	m.values[name] = data
	return nil
}

func (m *memoryCredentials) RemoveCredential(name string) error {
	if m.deleteError != nil {
		return m.deleteError
	}
	delete(m.values, name)
	return nil
}

type accountTransport func(*http.Request) (*http.Response, error)

func (f accountTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestAccountPersistencePrecedesPublication(t *testing.T) {
	ctx := context.Background()
	var offline bool
	transport := accountTransport(func(r *http.Request) (*http.Response, error) {
		if offline {
			return nil, errors.New("offline")
		}
		var body string
		switch r.URL.Path {
		case "/api/gettemplatevariable":
			body = `{"errno":0,"result":{"bdstoken":"test"}}`
		case "/api/user/getinfo":
			body = `{"errno":0,"records":[{"uk":123,"baidu_name":"百度样本"}]}`
		case "/c/s/login":
			body = `{"error_code":"0","user":{"id":123}}`
		case "/account/info":
			body = `{"success":true,"data":{"uid":"456","nickname":"夸克样本"}}`
		case "/1/clouddrive/file/sort":
			body = `{"status":200,"code":0,"data":{"list":[]}}`
		default:
			t.Fatalf("未预期的请求 %s", r.URL.Path)
		}
		return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
	})
	client := &http.Client{Transport: transport}
	records := &memoryCredentials{values: make(map[string][]byte)}
	accounts := NewAccounts(records, client)
	baiduCredential, err := baidu.ParseCredential("BDUSS=sample; STOKEN=sample")
	if err != nil {
		t.Fatal(err)
	}
	login, err := accounts.CheckBaidu(ctx, baiduCredential)
	if err != nil {
		t.Fatal(err)
	}
	if accounts.Session(Baidu).State != LoggedOut || len(records.values) != 0 {
		t.Fatal("校验阶段不能提交登录")
	}
	login.Discard()
	records.writeError = fs.ErrPermission
	login, err = accounts.CheckBaidu(ctx, baiduCredential)
	if err != nil {
		t.Fatal(err)
	}
	if err := accounts.Install(login); !errors.Is(err, fs.ErrPermission) || accounts.Session(Baidu).State != LoggedOut {
		t.Fatal("写入失败后发布了登录")
	}
	records.writeError = nil
	login, err = accounts.CheckBaidu(ctx, baiduCredential)
	if err != nil {
		t.Fatal(err)
	}
	if err := accounts.Install(login); err != nil {
		t.Fatal(err)
	}
	quarkCredential, err := quark.CredentialFromWebCookies([]quark.Cookie{
		{Name: "__pus", Value: "a", Domain: ".quark.cn"},
		{Name: "__kps", Value: "b", Domain: ".quark.cn"},
		{Name: "__uid", Value: "456", Domain: ".quark.cn"},
	})
	if err != nil {
		t.Fatal(err)
	}
	login, err = accounts.CheckQuark(ctx, quarkCredential)
	if err != nil {
		t.Fatal(err)
	}
	if err := accounts.Install(login); err != nil {
		t.Fatal(err)
	}
	records.deleteError = fs.ErrPermission
	if err := accounts.Logout(Quark); !errors.Is(err, fs.ErrPermission) || accounts.Session(Quark).ID != "456" {
		t.Fatal("删除失败应保留当前夸克会话")
	}
	records.deleteError = nil
	if err := accounts.Logout(Quark); err != nil {
		t.Fatal(err)
	}

	offline = true
	restored := NewAccounts(records, client)
	restored.Restore(ctx, Baidu, func() {})
	restored.Restore(ctx, Quark, func() {})
	if restored.Session(Baidu).ID != "123" || restored.Session(Baidu).State != LoggedIn || restored.Session(Quark).State != LoggedOut {
		t.Fatal("百度的已验证账号应离线恢复，且夸克退出不影响百度")
	}
}

func TestExpiryOnlyRetiresMatchingLiveSession(t *testing.T) {
	accounts := NewAccounts(nil, nil)
	previous := AccountSession{State: LoggedIn, ID: "owner", Baidu: baidu.New(baidu.Credential{}, nil)}
	defer previous.Baidu.Revoke()
	current := AccountSession{State: LoggedIn, ID: "owner", Baidu: baidu.New(baidu.Credential{}, nil)}
	accounts.slot(Baidu).current.Store(&current)
	notifications := 0
	accounts.OnExpired(func(provider Provider) {
		if provider != Baidu {
			t.Errorf("通知了不同网盘: %s", provider)
		}
		notifications++
	})
	if accounts.ExpireSession(Baidu, previous, baidu.ErrLoginExpired) ||
		accounts.ExpireSession(Baidu, current, context.DeadlineExceeded) {
		t.Fatal("旧会话或暂时网络故障不能使当前会话失效")
	}
	if !accounts.ExpireSession(Baidu, current, baidu.ErrLoginExpired) ||
		accounts.ExpireSession(Baidu, current, baidu.ErrLoginExpired) {
		t.Fatal("当前会话应只失效一次")
	}
	got := accounts.Session(Baidu)
	if got.State != Expired || got.ID != current.ID || got.Baidu != nil || notifications != 1 {
		t.Fatalf("失效后身份、凭据或通知不符: %+v，通知 %d 次", got, notifications)
	}
}
