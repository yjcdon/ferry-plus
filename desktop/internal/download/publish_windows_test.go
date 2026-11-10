package download

import (
	"errors"
	"io/fs"
	"os"
	"testing"
)

func TestWindowsPublishByHandle(t *testing.T) {
	root, err := os.OpenRoot(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()

	const partial = ".ferry-test.part"
	const existing = "existing.txt"
	const output = "比原临时文件名长的下载结果文件名.txt"
	for name, contents := range map[string]string{partial: "download", existing: "keep"} {
		if err := root.WriteFile(name, []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	info, err := root.Lstat(partial)
	if err != nil {
		t.Fatal(err)
	}
	stamp, err := publicationStamp(root, partial, info)
	if err != nil {
		t.Fatal(err)
	}
	wrong := *stamp
	wrong.Inode++
	if _, err := publishExclusive(root, partial, output, &wrong); err == nil {
		t.Fatal("rename accepted a different source identity")
	}
	if _, err := publishExclusive(root, partial, `..\escaped.txt`, stamp); err == nil {
		t.Fatal("rename accepted a destination outside the rooted directory")
	}
	if _, err := publishExclusive(root, partial, existing, stamp); !errors.Is(err, fs.ErrExist) {
		t.Fatalf("rename over existing file: %v", err)
	}
	if data, err := root.ReadFile(existing); err != nil || string(data) != "keep" {
		t.Fatalf("existing file changed: %q, %v", data, err)
	}

	renamed, err := publishExclusive(root, partial, output, stamp)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := root.Lstat(partial); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("original file name still exists: %v", err)
	}
	if data, err := root.ReadFile(output); err != nil || string(data) != "download" {
		t.Fatalf("renamed file: %q, %v", data, err)
	}
	info, err = root.Lstat(output)
	if err != nil {
		t.Fatal(err)
	}
	saved, err := publicationStamp(root, output, info)
	if err != nil || *saved != *renamed {
		t.Fatalf("renamed identity: got %+v, want %+v, error %v", saved, renamed, err)
	}
}
