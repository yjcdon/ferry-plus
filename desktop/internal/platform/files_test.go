package platform

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDownloadRelativePath(t *testing.T) {
	for _, remote := range []string{"", ".", "../file", "资料/../../file", "/file", "资料//file", `\server\file`, `C:relative`, "C:/file", "a\x00b"} {
		if _, err := DownloadRelativePath(remote); err == nil {
			t.Errorf("下载路径应拒绝 %q", remote)
		}
	}
	remote := "资料/说明 文档.txt"
	path, err := DownloadRelativePath(remote)
	if err != nil || path != filepath.Join("资料", "说明 文档.txt") {
		t.Fatalf("下载路径转换 = %q, %v", path, err)
	}
}

func TestDownloadRootRejectsEscapingLink(t *testing.T) {
	outside := t.TempDir()
	target := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(target, "目录")); err != nil {
		t.Skipf("环境无法创建符号链接: %v", err)
	}
	root, err := os.OpenRoot(target)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()

	path, err := DownloadRelativePath("目录/说明.txt")
	if err != nil {
		t.Fatal(err)
	}
	file, err := root.Create(path)
	if err == nil {
		file.Close()
		t.Fatal("下载文件不能通过符号链接落在目标目录之外")
	}
}
