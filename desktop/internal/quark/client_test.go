package quark

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

type fixtureTransport func(*http.Request) *http.Response

func (f fixtureTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	response := f(r)
	response.Request = r
	return response, nil
}

func fixtureResponse(status int, text string) *http.Response {
	return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(text))}
}

func fixtureSuccess(data string) *http.Response {
	return fixtureResponse(http.StatusOK, `{"status":200,"code":0,"data":`+data+`}`)
}

func fixtureBody(t *testing.T, request *http.Request) map[string]any {
	t.Helper()
	var body map[string]any
	if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	return body
}

func TestValidateAndCookiesOnRedirect(t *testing.T) {
	credential, err := CredentialFromWebCookies([]Cookie{
		{Name: "__pus", Value: "old", Domain: ".quark.cn", Path: "/", Secure: true},
		{Name: "__kps", Value: "local", Domain: "pan.quark.cn", Path: "/", Secure: true},
		{Name: "__uid", Value: "123", Domain: ".quark.cn", Path: "/", Secure: true},
		{Name: "foreign", Value: "private", Domain: ".other.test", Path: "/"},
	})
	if err != nil {
		t.Fatal(err)
	}
	var steps []string
	client := New(credential, &http.Client{Transport: fixtureTransport(func(request *http.Request) *http.Response {
		steps = append(steps, request.URL.Path)
		if request.Method != http.MethodGet || request.Header.Get("User-Agent") != userAgent ||
			request.Header.Get("Referer") != referer || request.Header.Get("Origin") != "https://pan.quark.cn" {
			t.Fatalf("unexpected login request: %v", request)
		}
		cookies := request.Header.Get("Cookie")
		switch request.URL.Path {
		case "/account/info":
			if request.URL.Query().Get("platform") != "pc" || !strings.Contains(cookies, "__pus=old") {
				t.Fatalf("wrong account request: %v %q", request.URL.Query(), cookies)
			}
			response := fixtureResponse(http.StatusFound, "")
			response.Header.Set("Location", "/account/result")
			response.Header.Add("Set-Cookie", "__pus=new; Domain=quark.cn; Path=/; Secure")
			response.Header.Add("Set-Cookie", "foreign=ignored; Domain=other.test; Path=/")
			return response
		case "/account/result":
			if cookies != "__pus=new; __kps=local; __uid=123" {
				t.Fatalf("cookies on follow-up: %q", cookies)
			}
			return fixtureResponse(http.StatusOK, `{"success":true,"code":"OK","data":{"uid":123,"nickname":"Ferry"}}`)
		case "/1/clouddrive/file/sort":
			query := request.URL.Query()
			if request.URL.Host != pcHost || query.Get("_size") != "1" || query.Get("pdir_fid") != "0" ||
				query.Get("_sort") != "file_type:asc,updated_at:desc" || cookies != "__pus=new; __uid=123" {
				t.Fatalf("unexpected access check: %v %q", request.URL, cookies)
			}
			return fixtureSuccess(`{"list":[]}`)
		default:
			t.Fatalf("unexpected request: %s", request.URL)
			return nil
		}
	})})
	var saved Credential
	client.ObserveCredentialChanges(func(next Credential) error { saved = next; return nil })
	login, err := client.Validate(t.Context(), "123")
	if err != nil || login.Account != (Account{ID: "123", Nickname: "Ferry"}) ||
		!reflect.DeepEqual(login.Credential, saved) || len(steps) != 3 {
		t.Fatalf("login = %+v, error = %v, steps = %v", login, err, steps)
	}
	client.Revoke()
	if _, err := client.Validate(t.Context(), ""); !errors.Is(err, context.Canceled) {
		t.Fatalf("revoked client used: %v", err)
	}
}

func TestRedirectCannotEscapeQuark(t *testing.T) {
	requests := 0
	client := New(Credential{}, &http.Client{Transport: fixtureTransport(func(request *http.Request) *http.Response {
		requests++
		response := fixtureResponse(http.StatusTemporaryRedirect, "")
		response.Header.Set("Location", "https://quark.cn.foreign.test/path")
		return response
	})})
	if _, err := client.Capacity(t.Context()); !errors.Is(err, ErrUnsafeRedirect) || requests != 1 {
		t.Fatalf("unexpected redirect result: %v, requests %d", err, requests)
	}
}

func TestListsAllPagesOrReturnsNoPartialResults(t *testing.T) {
	for _, failure := range []bool{false, true} {
		t.Run(fmt.Sprint("second-page-failure-", failure), func(t *testing.T) {
			pages := 0
			client := New(Credential{}, &http.Client{Transport: fixtureTransport(func(request *http.Request) *http.Response {
				pages++
				query := request.URL.Query()
				if request.URL.Host != pcHost || request.URL.Path != "/1/clouddrive/file/sort" || query.Get("pdir_fid") != "selected" ||
					query.Get("_page") != fmt.Sprint(pages) || query.Get("_size") != "100" || query.Get("_fetch_total") != "1" {
					t.Fatalf("unexpected page request: %s", request.URL)
				}
				if pages == 2 && failure {
					return fixtureResponse(http.StatusOK, `{"status":400,"code":"401","data":{"list":3}}`)
				}
				start, end := 0, 100
				if pages == 2 {
					start, end = 100, 101
				}
				files := make([]map[string]any, 0, end-start)
				for i := start; i < end; i++ {
					files = append(files, map[string]any{"fid": fmt.Sprint(i), "file_name": "file.bin", "dir": false, "size": 1, "pdir_fid": "selected"})
				}
				data, err := json.Marshal(files)
				if err != nil {
					t.Fatal(err)
				}
				return fixtureResponse(http.StatusOK, `{"status":200,"code":0,"data":{"list":`+string(data)+`},"metadata":{"_total":101}}`)
			})})
			entries, err := client.ListDirectory(t.Context(), "selected")
			if pages != 2 || (failure && (!errors.Is(err, ErrLoginExpired) || entries != nil)) ||
				(!failure && (err != nil || len(entries) != 101 || entries[100].FID != "100")) {
				t.Fatalf("pages=%d count=%d error=%v", pages, len(entries), err)
			}
		})
	}
}

func TestSharePreservesTokenAndChecksTaskIdentity(t *testing.T) {
	const token = "synthetic+base64/token=="
	client := New(Credential{}, &http.Client{Transport: fixtureTransport(func(request *http.Request) *http.Response {
		switch request.URL.Path {
		case "/1/clouddrive/share/sharepage/token":
			if request.URL.Host != panHost || !reflect.DeepEqual(fixtureBody(t, request), map[string]any{"pwd_id": "test123", "passcode": "a1B2"}) {
				t.Fatalf("unexpected token request: %v", request.URL)
			}
			return fixtureSuccess(`{"stoken":"` + token + `"}`)
		case "/1/clouddrive/share/sharepage/detail":
			if request.URL.Host != panHost || request.URL.Query().Get("stoken") != token || !strings.Contains(request.URL.RawQuery, "%2B") {
				t.Fatalf("unexpected detail request: %v", request.URL)
			}
			return fixtureSuccess(`{"list":[{"fid":"file","file_name":"示例.txt","size":12,"dir":false,"pdir_fid":"publisher","share_fid_token":"entry-token"}]}`)
		case "/1/clouddrive/share/sharepage/save":
			if request.URL.Host != pcHost || !reflect.DeepEqual(fixtureBody(t, request), map[string]any{
				"fid_list": []any{"file"}, "fid_token_list": []any{"entry-token"}, "to_pdir_fid": "owned",
				"pwd_id": "test123", "stoken": token, "pdir_fid": "0", "scene": "link",
			}) {
				t.Fatalf("unexpected save request: %v", request.URL)
			}
			return fixtureSuccess(`{"task_id":"saved"}`)
		case "/1/clouddrive/task":
			return fixtureResponse(http.StatusOK, `{"status":400,"code":32003,"message":"capacity","data":{"status":3,"task_id":"saved"}}`)
		default:
			t.Fatalf("unexpected request %v", request.URL)
			return nil
		}
	})})
	link, err := ParseShareLink("链接：https://pan.quark.cn/s/test123 提取码：a1B2")
	if err != nil {
		t.Fatal(err)
	}
	session, err := client.OpenShare(t.Context(), link)
	if err != nil {
		t.Fatal(err)
	}
	entries, err := client.ListShareDirectory(t.Context(), session, RootFID)
	if err != nil || len(entries) != 1 || entries[0].ParentFID != "publisher" {
		t.Fatalf("entries=%v error=%v", entries, err)
	}
	id, err := client.SubmitSave(t.Context(), session, entries, "owned", RootFID)
	if err != nil || id != "saved" {
		t.Fatalf("id=%q error=%v", id, err)
	}
	_, err = client.WaitForTask(t.Context(), id, 1, time.Second)
	var taskError *TransferTaskError
	if !errors.As(err, &taskError) || taskError.ID != id || taskError.Status != TaskFailed || !strings.Contains(taskError.Reason, "空间不足") {
		t.Fatalf("wrong terminal error: %v", err)
	}
	_, err = client.QueryTask(t.Context(), "other", 0)
	var serviceError *ServiceError
	if !errors.As(err, &serviceError) || serviceError.Code != "32003" {
		t.Fatalf("foreign failure should retain service error: %v", err)
	}
}

func TestFileMutationsAndDownloadHeaders(t *testing.T) {
	credential := Credential{Cookies: []Cookie{{Name: "auth", Value: "drive", Domain: ".quark.cn", Path: "/"}}}
	client := New(credential, &http.Client{Transport: fixtureTransport(func(request *http.Request) *http.Response {
		if request.Method != http.MethodPost || request.Header.Get("Content-Type") != "application/json;charset=UTF-8" ||
			request.Header.Get("Cookie") != "auth=drive" || request.URL.Query().Get("pr") != "ucpro" {
			t.Fatalf("unexpected request %v", request)
		}
		body := fixtureBody(t, request)
		switch request.URL.Path {
		case "/1/clouddrive/file":
			if request.URL.Host != pcHost || body["file_name"] != "资料" || body["pdir_fid"] != "0" || body["dir_init_lock"] != false {
				t.Fatalf("create body: %v", body)
			}
			return fixtureSuccess(`{"fid":"dir"}`)
		case "/1/clouddrive/file/rename":
			if request.URL.Host != pcHost || body["fid"] != "dir" || body["file_name"] != "整理" {
				t.Fatalf("rename body: %v", body)
			}
			return fixtureSuccess("null")
		case "/1/clouddrive/file/delete":
			if request.URL.Host != driveHost || !reflect.DeepEqual(body, map[string]any{"action_type": float64(1), "exclude_fids": []any{}, "filelist": []any{"dir"}}) {
				t.Fatalf("recycle body: %v", body)
			}
			return fixtureSuccess("null")
		case "/1/clouddrive/file/download":
			if request.URL.Host != driveHost || !reflect.DeepEqual(body["fids"], []any{"file"}) {
				t.Fatalf("download body: %v", body)
			}
			return fixtureSuccess(`[{"fid":"file","size":12,"download_url":"https://download.test/file"}]`)
		default:
			t.Fatalf("unexpected request %v", request.URL)
			return nil
		}
	})})
	ctx := t.Context()
	id, err := client.CreateDirectory(ctx, "资料", RootFID)
	if err != nil || id != "dir" {
		t.Fatalf("created %q: %v", id, err)
	}
	if err := client.Rename(ctx, id, "整理"); err != nil {
		t.Fatal(err)
	}
	if err := client.Delete(ctx, []string{id}); err != nil {
		t.Fatal(err)
	}
	download, err := client.Download(ctx, "file")
	if err != nil || download.URL.Host != "download.test" || download.Headers.Get("Cookie") != "" ||
		download.Headers.Get("User-Agent") != userAgent || download.Size == nil || *download.Size != 12 {
		t.Fatalf("download=%v err=%v", download, err)
	}
}
