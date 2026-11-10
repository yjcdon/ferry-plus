package core

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
	"github.com/yjcdon/ferry-drive/desktop/internal/quark"
)

func TestUploadContentGateIsDurableAndStopsBeforeRemoteCalls(t *testing.T) {
	records := uploadFixtureRecords{make(map[string][]byte), make(map[string][]byte)}
	remoteCalls := 0
	client := &http.Client{Transport: uploadRoundTrip(func(*http.Request) (*http.Response, error) {
		remoteCalls++
		return nil, errors.New("duplicate gate did not stop remote work")
	})}
	uploader := newUploader(records, client)
	providers := UploadProviders{AccountID: "fixture", Quark: quark.New(quark.Credential{}, client)}
	target := UploadTarget{Provider: "quark", AccountID: "fixture", FID: quark.RootFID}
	rejected := errors.New("duplicate candidate paused")
	makeSources := func(parent, content string, extraEmpty bool) []platform.LocalReference {
		t.Helper()
		root := filepath.Join(parent, "资料")
		if err := os.MkdirAll(filepath.Join(root, "空目录"), 0o700); err != nil {
			t.Fatal(err)
		}
		if extraEmpty {
			if err := os.Mkdir(filepath.Join(root, "空目录2"), 0o700); err != nil {
				t.Fatal(err)
			}
		}
		if err := os.WriteFile(filepath.Join(root, "数据.txt"), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		extra := filepath.Join(parent, "附加.txt")
		if err := os.WriteFile(extra, []byte{}, 0o600); err != nil {
			t.Fatal(err)
		}
		return []platform.LocalReference{{Path: root}, {Path: extra}}
	}
	run := func(id string, sources []platform.LocalReference) string {
		t.Helper()
		var got string
		_, err := uploader.Run(t.Context(), UploadRequest{ID: id, Target: target, Sources: sources,
			BeforeRemote: func(signature string, canPause bool) error {
				var manifest uploadManifest
				if err := records.Read(uploadJobKey(id), &manifest); err != nil {
					t.Fatal(err)
				}
				if manifest.Signature != signature || len(signature) != 64 || !canPause || manifest.RemoteStarted {
					t.Fatalf("unexpected duplicate state: %q, canPause=%t, manifest=%+v", signature, canPause, manifest)
				}
				for _, entry := range manifest.Entries {
					if entry.Directory {
						continue
					}
					var saved uploadItemState
					if err := records.Read(uploadItemKey(uploadJobKey(id), entry.Relative), &saved); err != nil || saved.Fingerprint.SHA256 == "" {
						t.Fatalf("basis was not saved before the gate: %s, %v", entry.Relative, err)
					}
				}
				got = signature
				return rejected
			}}, providers, nil)
		if !errors.Is(err, rejected) || got == "" || remoteCalls != 0 {
			t.Fatalf("signature=%q, error=%v, remote calls=%d", got, err, remoteCalls)
		}
		return got
	}
	first := makeSources(t.TempDir(), "hello", false)
	original := run("one", first)
	if err := os.Rename(first[0].Path, first[0].Path+".moved"); err != nil {
		t.Fatal(err)
	}
	if got := run("one", first); got != original {
		t.Fatal("retry did not reuse durable content signature")
	}
	for i, fixture := range []struct {
		text  string
		extra bool
		equal bool
	}{
		{"hello", false, true},
		{"HELLO", false, false},
		{"hello", true, false},
	} {
		sources := makeSources(t.TempDir(), fixture.text, fixture.extra)
		sources[0], sources[1] = sources[1], sources[0]
		signature := run(fmt.Sprintf("job-%d", i), sources)
		if (signature == original) != fixture.equal {
			t.Fatalf("case %d: signature %s, baseline %s", i, signature, original)
		}
	}
}
