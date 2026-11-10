package core

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

func TestRevealUploadSourceUsesNestedPathOrReboundReference(t *testing.T) {
	records := uploadFixtureRecords{make(map[string][]byte), make(map[string][]byte)}
	uploader := newUploader(records, nil)
	root := t.TempDir()
	original := filepath.Join(root, "source.txt")
	replacement := filepath.Join(t.TempDir(), "moved.txt")
	for _, path := range []string{original, replacement} {
		if err := os.WriteFile(path, nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	manifest := uploadManifest{Sources: []platform.LocalReference{{Path: root}},
		Entries: []uploadLocalItem{{Relative: "目录/source.txt", Inside: "source.txt"}}}
	save := func() {
		t.Helper()
		if err := records.Write(uploadJobKey("job"), manifest); err != nil {
			t.Fatal(err)
		}
	}
	expect := func(want string) {
		t.Helper()
		err := uploader.withUploadSourcePath("job", "目录/source.txt", func(got string) error {
			if got != want {
				t.Fatalf("opened %q, want %q", got, want)
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	save()
	expect(original)
	manifest.Entries[0].Replacement = &platform.LocalReference{Path: replacement}
	save()
	expect(replacement)
	if err := os.Rename(replacement, replacement+".gone"); err != nil {
		t.Fatal(err)
	}
	err := uploader.withUploadSourcePath("job", "目录/source.txt", func(string) error {
		t.Fatal("revealed a missing local source")
		return nil
	})
	if !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("missing source error = %v", err)
	}
}
