package core

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/quark"
)

func TestCanceledQuarkUploadInspectsExactReceiptWithoutCompletingUpload(t *testing.T) {
	records := uploadFixtureRecords{make(map[string][]byte), make(map[string][]byte)}
	var requests []string
	client := &http.Client{Transport: uploadRoundTrip(func(r *http.Request) (*http.Response, error) {
		requests = append(requests, r.Method+" "+r.URL.Path)
		if r.Method != http.MethodGet || r.URL.Path != "/1/clouddrive/file/sort" || r.URL.Query().Get("pdir_fid") != "parent" {
			return nil, fmt.Errorf("unexpected remote operation: %s %s", r.Method, r.URL)
		}
		body := `{"status":200,"code":0,"data":{"list":[{"fid":"unrelated","file_name":"file.txt","size":3,"dir":false,"pdir_fid":"parent"},{"fid":"exact","file_name":"file.txt","size":3,"dir":false,"pdir_fid":"parent"}]}}`
		return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Request: r, Body: io.NopCloser(strings.NewReader(body))}, nil
	})}
	uploader := newUploader(records, client)
	req := UploadRequest{ID: "canceled", Target: UploadTarget{Provider: "quark", AccountID: "fixture", FID: "parent"}}
	key := uploadJobKey(req.ID)
	if err := records.Write(key, uploadManifest{Target: req.Target, Entries: []uploadLocalItem{
		{Relative: "file.txt", Size: 3}, {Relative: "merged.txt", Size: 3},
	}}); err != nil {
		t.Fatal(err)
	}
	receipt := quark.UploadSession{TaskID: "task", FileID: "exact", UploadID: "upload", ObjectKey: "object",
		Bucket: "test", StorageHost: "oss.quark.cn", ParentFID: "parent", Name: "file.txt", Size: 3, PartSize: 3}
	if err := records.Write(uploadItemKey(key, "file.txt"), uploadItemState{Intent: "quark-merge", Quark: &receipt}); err != nil {
		t.Fatal(err)
	}
	receipt.FileID, receipt.Name = "not-finished", "merged.txt"
	if err := records.Write(uploadItemKey(key, "merged.txt"), uploadItemState{Intent: "quark-merged", Quark: &receipt}); err != nil {
		t.Fatal(err)
	}
	if pending, err := uploader.HasPendingUpload(req.ID); err != nil || !pending || len(requests) != 0 {
		t.Fatalf("local pending probe = %v, err=%v, requests=%v", pending, err, requests)
	}
	providers := UploadProviders{AccountID: "fixture", Quark: quark.New(quark.Credential{}, client)}
	items, err := uploader.ReconcileCanceledUpload(t.Context(), req, providers)
	if err != nil || len(items) != 1 || items[0].FID != "exact" || items[0].Complete || len(requests) != 1 {
		t.Fatalf("confirmed objects = %+v, err=%v, requests=%v", items, err, requests)
	}
	if pending, err := uploader.HasPendingUpload(req.ID); err != nil || pending {
		t.Fatalf("confirmed receipt remained pending: %v, %v", pending, err)
	}
	if items, err := uploader.ReconcileCanceledUpload(t.Context(), req, providers); err != nil || len(items) != 1 || len(requests) != 1 {
		t.Fatalf("repeat check changed the provider: %+v, %v, requests=%v", items, err, requests)
	}
}

func TestCanceledUploadWithoutExactIdentityRemainsPending(t *testing.T) {
	records := uploadFixtureRecords{make(map[string][]byte), make(map[string][]byte)}
	uploader := newUploader(records, &http.Client{Transport: uploadRoundTrip(func(r *http.Request) (*http.Response, error) {
		t.Errorf("unknown identity contacted provider: %v", r.URL)
		return nil, errors.New("unexpected request")
	})})
	req := UploadRequest{ID: "baidu-canceled", Target: UploadTarget{Provider: "baidu", AccountID: "fixture", Path: "/"}}
	key := uploadJobKey(req.ID)
	if err := records.Write(key, uploadManifest{Target: req.Target, Entries: []uploadLocalItem{{Relative: "file.txt", Size: 3}}}); err != nil {
		t.Fatal(err)
	}
	if err := records.Write(uploadItemKey(key, "file.txt"), uploadItemState{Intent: "baidu-merge", Name: "file.txt"}); err != nil {
		t.Fatal(err)
	}
	items, err := uploader.ReconcileCanceledUpload(t.Context(), req, UploadProviders{AccountID: "fixture"})
	if !errors.Is(err, ErrUploadUnconfirmed) || len(items) != 0 {
		t.Fatalf("unknown intent was treated as resolved: %+v, %v", items, err)
	}
	if pending, err := uploader.HasPendingUpload(req.ID); err != nil || !pending {
		t.Fatalf("unknown intent was cleared: %v, %v", pending, err)
	}
}
