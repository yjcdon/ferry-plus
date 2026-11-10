package app

import (
	"errors"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
	"github.com/yjcdon/ferry-drive/desktop/internal/quark"
)

func TestShareRootCreationRetriesOnlyConfirmedRejections(t *testing.T) {
	for _, fixture := range []struct {
		name     string
		provider Provider
		body     any
		rejected bool
		cause    error
	}{
		{"baidu-permission", Baidu, map[string]any{"error_code": 31064}, true, baidu.ErrAccessDenied},
		{"baidu-login", Baidu, map[string]any{"error_code": -6}, true, baidu.ErrLoginExpired},
		{"baidu-quota", Baidu, map[string]any{"error_code": -10}, true, nil},
		{"baidu-lost-response", Baidu, nil, false, nil},
		{"baidu-missing-identity", Baidu, map[string]any{"error_code": 0}, false, baidu.ErrInvalidResponse},
		{"quark-permission", Quark, map[string]any{"status": 400, "code": 403}, true, quark.ErrLoginExpired},
		{"quark-quota", Quark, map[string]any{"status": 400, "code": 32003}, true, nil},
		{"quark-lost-response", Quark, nil, false, nil},
		{"quark-missing-identity", Quark, map[string]any{"status": 200, "code": 0, "data": map[string]any{}}, false, quark.ErrInvalidResponse},
		{"quark-missing-result", Quark, map[string]any{}, false, nil},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			creates := 0
			transport := directoryTransport(func(r *http.Request) (*http.Response, error) {
				switch r.URL.Path {
				case "/api/list":
					return directoryList(t, r, nil)
				case "/1/clouddrive/file/sort":
					return directoryReply(t, r, map[string]any{"status": 200, "code": 0, "data": map[string]any{"list": []any{}}})
				case "/rest/2.0/pcs/file", "/1/clouddrive/file":
					creates++
					if creates > 1 || fixture.body == nil {
						return nil, errors.New("response lost after creating directory")
					}
					return directoryReply(t, r, fixture.body)
				}
				return nil, fmt.Errorf("unexpected request %s", r.URL)
			})
			records := shareTestStore{make(map[string][]byte), make(map[string][]byte)}
			accounts := NewAccounts(records, nil)
			session := newDirectorySession(t, "owner", transport)
			if fixture.provider == Quark {
				session = AccountSession{ID: "owner", State: LoggedIn, Quark: quark.New(quark.Credential{}, &http.Client{Transport: transport})}
			}
			accounts.slot(fixture.provider).current.Store(&session)
			key := shareJobKey("creation")
			record := shareTransferRecord{
				Provider: fixture.provider, AccountID: session.ID, BaseFolder: "/",
				Expected: []shareExpected{{Path: "file.txt", Size: 5}},
			}
			if err := records.Write(key, record); err != nil {
				t.Fatal(err)
			}
			_, err := newShareTransfer(records, accounts).Resume(t.Context(), "creation")
			if err == nil || errors.Is(err, ErrShareTransferUnconfirmed) == fixture.rejected || creates != 1 {
				t.Fatalf("creation rejection classification: %v, attempts=%d", err, creates)
			}
			if fixture.cause != nil && !errors.Is(err, fixture.cause) {
				t.Fatalf("lost provider error: %v", err)
			}
			if err := records.Read(key, &record); err != nil || record.MakingRoot == fixture.rejected {
				t.Fatalf("incorrect saved creation intent: %+v, %v", record, err)
			}
			// A fresh service instance must recover the durable decision. A
			// retried request now loses its response and must remain ambiguous.
			_, err = newShareTransfer(records, accounts).Resume(t.Context(), "creation")
			wantCreates := 1
			if fixture.rejected {
				wantCreates = 2
			}
			if !errors.Is(err, ErrShareTransferUnconfirmed) || creates != wantCreates {
				t.Fatalf("restart reissued an ambiguous request or blocked a rejection: %v, attempts=%d", err, creates)
			}
		})
	}
}

func TestBaiduShareMetadataDoesNotBecomeTrustedContentDigest(t *testing.T) {
	transport := directoryTransport(func(r *http.Request) (*http.Response, error) {
		return directoryList(t, r, []baiduRow{{ID: 2, Path: "/owned/file.txt", Size: 5}})
	})
	items, err := collectShareDownload(t.Context(), newDirectorySession(t, "owner", transport),
		RemoteRef{Provider: Baidu, ID: "1", Path: "/owned"},
		[]shareExpected{{Path: "file.txt", Size: 5, MD5: strings.Repeat("a", 32)}})
	if err != nil || len(items) != 1 {
		t.Fatalf("manifest collection: %+v, %v", items, err)
	}
	if items[0].ExpectedMD5 != "" || items[0].ExpectedSHA256 != "" {
		t.Fatalf("Baidu metadata became a trusted content expectation: %+v", items[0])
	}
}
