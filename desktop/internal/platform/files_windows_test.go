package platform

import "testing"

func TestWindowsDownloadNames(t *testing.T) {
	for _, path := range []string{"CON.txt", "目录/lpt²", "资料./文档", "文件 ", `目录\文件`, "文件?.txt", "文档:备份", "bad\rname"} {
		if _, err := DownloadRelativePath(path); err == nil {
			t.Errorf("Windows 下载路径应拒绝 %q", path)
		}
	}
}
