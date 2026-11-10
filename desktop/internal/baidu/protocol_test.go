package baidu

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"reflect"
	"strings"
	"testing"
	"time"
)

type stubTransport func(*http.Request) (*http.Response, error)

func (s stubTransport) RoundTrip(r *http.Request) (*http.Response, error) { return s(r) }

func reply(r *http.Request, status int, body string, headers http.Header) *http.Response {
	return &http.Response{Request: r, StatusCode: status, Header: headers, Body: io.NopCloser(strings.NewReader(body))}
}

func testClient(t *testing.T, transport stubTransport) *Client {
	t.Helper()
	credential, err := ParseCredential("cookie: BDUSS=test_bduss; STOKEN=test_stoken; PANPSC=old; RT=\"a=b\"")
	if err != nil {
		t.Fatal(err)
	}
	client := New(credential, &http.Client{Transport: transport})
	client.now = func() time.Time { return time.Unix(1571140066, 0) }
	return client
}

func TestCredentialSelectsCookiesForNetdiskRoot(t *testing.T) {
	now := time.Unix(100, 0)
	credential, err := CredentialFromCookies([]BrowserCookie{
		{Cookie: Cookie{"STOKEN", "passport"}, Domain: "passport.baidu.com", Path: "/"},
		{Cookie: Cookie{"STOKEN", "expired"}, Domain: ".baidu.com", Path: "/", Expires: now},
		{Cookie: Cookie{"STOKEN", "other path"}, Domain: ".baidu.com", Path: "/disk"},
		{Cookie: Cookie{"STOKEN", "newer"}, Domain: "pan.baidu.com", Path: "/", Created: time.Unix(2, 0)},
		{Cookie: Cookie{"STOKEN", "earlier"}, Domain: "pan.baidu.com", Path: "/", Created: time.Unix(1, 0)},
		{Cookie: Cookie{"BDUSS", "web"}, Domain: ".baidu.com", Path: "/"},
	}, now)
	if err != nil {
		t.Fatal(err)
	}
	if credential.STOKEN != "earlier" || credential.BDUSS != "web" {
		t.Fatal("unexpected browser cookie order or scope")
	}
	copied, err := ParseCredential("Cookie: STOKEN=old; invalid; STOKEN=new; RT=\"a=b\"; BDUSS=last")
	if err != nil {
		t.Fatal(err)
	}
	if copied.STOKEN != "new" || copied.BDUSS != "last" || cookieHeader(copied.Cookies) != "STOKEN=new; RT=a=b; BDUSS=last" {
		t.Fatal("unexpected copied cookie normalization")
	}
}

func TestAccountAndSignedDownload(t *testing.T) {
	var tiebaCalls int
	client := testClient(t, func(r *http.Request) (*http.Response, error) {
		q := r.URL.Query()
		switch r.URL.Path {
		case "/api/gettemplatevariable":
			if q.Get("fields") != `["bdstoken"]` || q.Get("app_id") != "250528" {
				t.Fatal("invalid template query")
			}
			return reply(r, 200, `{"errno":0,"result":{"bdstoken":"a123"}}`, nil), nil
		case "/api/user/getinfo":
			return reply(r, 200, `{"errno":0,"records":[{"uk":"10086","baidu_name":"fallback"}]}`, nil), nil
		case "/c/s/login":
			tiebaCalls++
			if err := r.ParseForm(); err != nil {
				t.Fatal(err)
			}
			if r.Form.Get("bdusstoken") != "test_bduss|null" || r.Form.Get("timestamp") != "1571140066922" ||
				r.Form.Get("sign") != "CC0C8CA80E8AA195B3C00E0874A3BED1" || r.Header.Get("Cookie") != "ka=open" {
				t.Fatal("Tieba request differs from the Swift signing vector")
			}
			return reply(r, 200, `{"error_code":"0","user":{"id":10086,"name":"account"}}`, nil), nil
		case "/rest/2.0/pcs/file":
			if !strings.HasPrefix(r.URL.RawQuery, "ant=1&apn_id=1_0&app_id=250528&channel=0&check_blue=1&clienttype=17&es=1&esl=1&freeisp=0&method=locatedownload&path=%2FFerry%2Fa%20b%2Bc.zip&queryfree=0&use=0&ver=4.0&time=1571140066&rand=") ||
				q.Get("devuid") != "66AE65D3C5D483FC4431FC43670A4673|0" || r.Header.Get("User-Agent") != netdiskUA {
				t.Fatal("incorrect signed download query or headers")
			}
			return reply(r, 200, `{"urls":[{"url":"http://nb.cache.invalid/f","encrypt":0},{"url":"http://cache.invalid/f","encrypt":0},{"url":"http://encrypted.invalid/f","encrypt":1}]}`, nil), nil
		}
		return nil, fmt.Errorf("unexpected endpoint %s", r.URL.Path)
	})
	account, err := client.Validate(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if account.UK != 10086 || account.UID == nil || *account.UID != 10086 || account.Username != "account" {
		t.Fatalf("unexpected account: %+v", account)
	}
	link, err := client.DownloadLink(context.Background(), "/Ferry/a b+c.zip", 0)
	if err != nil {
		t.Fatal(err)
	}
	if link.URL.String() != "https://cache.invalid/f" || link.Source != DownloadSourceLocate || !strings.Contains(link.Headers.Get("Cookie"), "STOKEN=test_stoken") || tiebaCalls != 1 {
		t.Fatal("wrong download link selection, headers or UID reuse")
	}
}

func TestDirectoryPaginationAndDuplicateDetection(t *testing.T) {
	duplicate := false
	client := testClient(t, func(r *http.Request) (*http.Response, error) {
		q := r.URL.Query()
		if q.Get("dir") != "/测试+空 格" || q.Get("num") != "1000" || q.Get("order") != "name" {
			t.Fatal("wrong directory query")
		}
		if q.Get("page") == "2" {
			id := 1001
			if duplicate {
				id = 1000
			}
			return reply(r, 200, fmt.Sprintf(`{"errno":0,"list":[{"fs_id":"%d","path":"/last","isdir":0,"size":"0"}]}`, id), nil), nil
		}
		items := make([]map[string]any, 1000)
		for i := range items {
			items[i] = map[string]any{"fs_id": i + 1, "path": fmt.Sprintf("/file-%d", i), "isdir": "0", "size": 0}
		}
		data, err := json.Marshal(map[string]any{"errno": 0, "list": items})
		if err != nil {
			t.Fatal(err)
		}
		return reply(r, 200, string(data), nil), nil
	})
	entries, err := client.ListDirectory(context.Background(), "/测试+空 格")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1001 || entries[1000].FSID != 1001 {
		t.Fatal("directory page was dropped")
	}
	duplicate = true
	entries, err = client.ListDirectory(context.Background(), "/测试+空 格")
	if !errors.Is(err, ErrInvalidResponse) || entries != nil {
		t.Fatal("inconsistent listing leaked partial results")
	}
}

func TestShareSessionCookiesAndRootRequest(t *testing.T) {
	page := func(token string) string {
		return fmt.Sprintf(`<script>locals.mset({"loginstate":1,"bdstoken":"%s","shareid":"3003","share_uk":2002});</script>`, token)
	}
	calls := 0
	client := testClient(t, func(r *http.Request) (*http.Response, error) {
		calls++
		switch calls {
		case 1:
			if r.URL.Path != "/s/1qYZEsSc" || r.Header.Get("User-Agent") != netdiskUA {
				t.Fatal("wrong initial share request")
			}
			return reply(r, 200, page("aaaa1111"), http.Header{"Set-Cookie": {"PANPSC=; expires=Fri, 01-Apr-1900 00:00:00 GMT; path=/"}}), nil
		case 2:
			if err := r.ParseForm(); err != nil {
				t.Fatal(err)
			}
			if r.URL.Path != "/share/verify" || r.URL.Query().Get("uk") != "2002" || r.Header.Get("User-Agent") != macUA ||
				r.Form.Get("pwd") != "ab12" || r.Form.Get("bdstoken") != "aaaa1111" || strings.Contains(r.Header.Get("Cookie"), "PANPSC") {
				t.Fatal("wrong share verification request")
			}
			return reply(r, 200, `{"errno":0,"randsk":"ignored"}`, http.Header{"Set-Cookie": {"BDCLND=from%2Fcookie; path=/"}}), nil
		case 3:
			if r.Header.Get("Referer") != pan+"/share/init?surl=qYZEsSc" || !strings.Contains(r.Header.Get("Cookie"), "BDCLND=from%2Fcookie") {
				t.Fatal("share page lost verification state")
			}
			return reply(r, 200, page("bbbb2222"), nil), nil
		case 4:
			q := r.URL.Query()
			if q.Get("root") != "1" || q.Has("page") || q.Has("num") || q.Get("bdstoken") != "bbbb2222" {
				t.Fatal("wrong root listing request")
			}
			return reply(r, 200, `{"errno":0,"list":[{"fs_id":1,"path":"/sharer/a.zip","isdir":0,"size":10}]}`, nil), nil
		}
		return nil, fmt.Errorf("unexpected request")
	})
	link, err := ParseShareLink("链接 https://pan.baidu.com/s/1qYZEsSc 提取码：ab12")
	if err != nil {
		t.Fatal(err)
	}
	s, err := client.OpenShare(context.Background(), link, "")
	if err != nil {
		t.Fatal(err)
	}
	entries, err := client.ListShare(context.Background(), s, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].RelativePath() != "a.zip" || !s.DeletedCookies["PANPSC"] || calls != 4 {
		t.Fatal("wrong share session or root entries")
	}
}

func TestUploadStageRequestAndReceipt(t *testing.T) {
	const digest = "900150983cd24fb0d6963f7d28e17f72"
	ctx := context.Background()
	client := testClient(t, func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/api/gettemplatevariable":
			return reply(r, 200, `{"errno":0,"result":{"bdstoken":"a123"}}`, nil), nil
		case "/api/precreate", "/api/create":
			if err := r.ParseForm(); err != nil {
				t.Fatal(err)
			}
			if r.Form.Get("rtype") != "0" || r.Form.Get("block_list") != `["`+digest+`"]` || r.Form.Get("path") != "/测试/a+b" || r.Header.Get("Referer") != pan+"/" {
				t.Fatal("wrong upload form")
			}
			if r.URL.Path == "/api/precreate" {
				return reply(r, 200, `{"errno":0,"return_type":1,"uploadid":"id","block_list":[0]}`, nil), nil
			}
			if r.Form.Get("uploadid") != "id" {
				t.Fatal("wrong merge session")
			}
			return reply(r, 200, `{"errno":0,"fs_id":101,"path":"/测试/a+b","isdir":0,"size":3}`, nil), nil
		case "/rest/2.0/pcs/superfile2":
			q := r.URL.Query()
			if r.URL.Host != "d.pcs.baidu.com" || q.Get("partseq") != "0" || q.Get("type") != "tmpfile" {
				t.Fatal("wrong part endpoint")
			}
			reader, err := r.MultipartReader()
			if err != nil {
				t.Fatal(err)
			}
			part, err := reader.NextPart()
			if err != nil {
				t.Fatal(err)
			}
			data, err := io.ReadAll(part)
			if err != nil {
				t.Fatal(err)
			}
			if part.FormName() != "file" || part.FileName() != "part.bin" || string(data) != "abc" {
				t.Fatal("wrong multipart part")
			}
			if _, err := reader.NextPart(); err != io.EOF {
				t.Fatal("incomplete multipart framing")
			}
			return reply(r, 200, `{"md5":"`+digest+`"}`, nil), nil
		}
		return nil, fmt.Errorf("unexpected path %s", r.URL.Path)
	})
	prep, err := client.PrepareUpload(ctx, "/测试/a+b", 3, []string{digest}, digest, digest)
	if err != nil {
		t.Fatal(err)
	}
	if prep.Session == nil || !reflect.DeepEqual(prep.Session.PendingParts, []int{0}) {
		t.Fatal("wrong upload plan")
	}
	if _, err := client.UploadPart(ctx, []byte("bad"), 0, *prep.Session); !errors.Is(err, ErrUploadSourceChanged) {
		t.Fatal("wrong bytes were accepted")
	}
	receipt, err := client.UploadPart(ctx, []byte("abc"), 0, *prep.Session)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.CompleteUpload(ctx, *prep.Session, nil); !errors.Is(err, ErrInvalidUploadPlan) {
		t.Fatal("merge accepted missing receipts")
	}
	entry, err := client.CompleteUpload(ctx, *prep.Session, []UploadPartReceipt{receipt})
	if err != nil || entry.FSID != 101 {
		t.Fatalf("wrong merge receipt: %+v, %v", entry, err)
	}
}

func TestSignedDownloadFallsBackOnlyForExplicitProviderFailure(t *testing.T) {
	code := 31044
	client := testClient(t, func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/c/s/login" {
			return reply(r, 200, `{"error_code":"1"}`, nil), nil
		}
		return reply(r, 403, fmt.Sprintf(`{"error_code":%d}`, code), nil), nil
	})
	got, err := client.DownloadLink(context.Background(), "/路径/a+b", 0)
	if err != nil || got.Source != DownloadSourcePCS || got.URL.Query().Get("path") != "/路径/a+b" {
		t.Fatalf("expected PCS fallback: %+v, %v", got, err)
	}
	code = 31066
	if _, err := client.DownloadLink(context.Background(), "/路径/a+b", 0); !errors.Is(err, ErrFileNotFound) {
		t.Fatalf("missing file should not fall back: %v", err)
	}
	client.Revoke()
	if _, err := client.ListDirectory(context.Background(), "/"); !errors.Is(err, context.Canceled) {
		t.Fatalf("revoked account accepted a new request: %v", err)
	}
}

func TestEncodedRequestValues(t *testing.T) {
	if got := encode(url.Values{"path": {"a b+c/中"}, "empty": {""}}); got != "empty=&path=a%20b%2Bc%2F%E4%B8%AD" {
		t.Fatalf("wrong RFC 3986 encoding: %s", got)
	}
}
