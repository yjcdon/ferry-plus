package app

import (
	"encoding/json"
	"errors"
	"io/fs"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

type settingsMemory struct {
	plain, secret           []byte
	plainError, secretError error
}

func (s *settingsMemory) Read(name string, dst any) error {
	if name != "settings" || s.plain == nil {
		return fs.ErrNotExist
	}
	return json.Unmarshal(s.plain, dst)
}
func (s *settingsMemory) Write(name string, value any) error {
	if s.plainError != nil {
		return s.plainError
	}
	var err error
	s.plain, err = json.Marshal(value)
	return err
}
func (s *settingsMemory) ReadCredential(name string) ([]byte, error) {
	if name != "settings-proxy" || s.secret == nil {
		return nil, fs.ErrNotExist
	}
	return s.secret, nil
}
func (s *settingsMemory) WriteCredential(name string, value []byte) error {
	if s.secretError != nil {
		return s.secretError
	}
	s.secret = value
	return nil
}

func TestSettingsDefaultsBoundsAndRestoration(t *testing.T) {
	data := &settingsMemory{}
	model, err := loadSettings(data)
	if err != nil {
		t.Fatal(err)
	}
	if values := model.Values(); !reflect.DeepEqual(values, DefaultSettings()) {
		t.Fatalf("首次读取未保留当前默认值 %+v", values)
	}
	if err := model.Update(func(v *SettingsValues) {
		v.MaxConcurrentFiles = 10
		v.Baidu.ConnectionsPerFile = 16
		v.Quark.ConnectionsPerFile = 3
		v.MaxConcurrentUploads = 8
		v.UploadPartsPerFile = 0
		v.UploadBytesPerSecond = -1024
		v.DownloadBytesPerSecond = 1024 * 50
		v.DetectsCopiedLinks = false
		v.Baidu.TransferFolder = "  ///网盘//保存/ "
		v.Quark.TransferFolder = " "
		v.SelectedTab = 2
	}); err != nil {
		t.Fatal(err)
	}
	reopened, err := loadSettings(data)
	if err != nil {
		t.Fatal(err)
	}
	v := reopened.Values()
	if v.MaxConcurrentFiles != 10 || v.Baidu.ConnectionsPerFile != 2 || v.Quark.ConnectionsPerFile != 2 ||
		v.MaxConcurrentUploads != 4 || v.UploadPartsPerFile != 1 || v.UploadBytesPerSecond != 0 ||
		v.DownloadBytesPerSecond != 50*1024 || v.DetectsCopiedLinks || v.Baidu.TransferFolder != "/网盘/保存" ||
		v.Quark.TransferFolder != "/Ferry Plus" || v.SelectedTab != 2 || v.AllowedConnections() != 2 || v.AllowedConcurrentFiles() != 10 {
		t.Fatalf("未按当前业务规则保存恢复 %+v", v)
	}
	data.plainError = fs.ErrPermission
	if err := reopened.Update(func(v *SettingsValues) { v.DetectsCopiedLinks = true }); !errors.Is(err, fs.ErrPermission) ||
		reopened.Values().DetectsCopiedLinks {
		t.Fatal("普通设置保存失败后发布了新状态")
	}
}

func TestProxyCredentialsAreCommittedTogether(t *testing.T) {
	data := &settingsMemory{}
	model, err := loadSettings(data)
	if err != nil {
		t.Fatal(err)
	}
	port := 1080
	proxy := platform.ProxySettings{Mode: platform.ProxySOCKS5, Host: " 127.0.0.1 ", Port: &port, Username: " ferry "}
	password := " password with spaces "
	if err := model.SetProxy(proxy, password); err != nil {
		t.Fatal(err)
	}
	if err := model.Update(func(v *SettingsValues) { v.SelectedTab = 1 }); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data.plain), password) || strings.Contains(string(data.plain), "settings-proxy") {
		t.Fatal("普通设置含有代理凭据")
	}
	*proxy.Port = 234
	cfg, secret := model.Proxy()
	if cfg.Host != "127.0.0.1" || cfg.Username != "ferry" || *cfg.Port != 1080 || secret != password || cfg.Problem(secret) != nil {
		t.Fatalf("代理字段未按契约恢复 %+v", cfg)
	}
	data.secretError = fs.ErrPermission
	if err := model.SetProxy(platform.ProxySettings{Mode: platform.ProxySOCKS5, Host: "offline"}, ""); !errors.Is(err, fs.ErrPermission) {
		t.Fatalf("未报告凭据保存错误 %v", err)
	}
	reopened, err := loadSettings(data)
	if err != nil {
		t.Fatal(err)
	}
	cfg, secret = reopened.Proxy()
	if cfg.Host != "127.0.0.1" || secret != password {
		t.Fatal("代理保存失败破坏了旧凭据")
	}
}

func TestSettingsUnavailableDownloadFolderDoesNotSilentlyFallback(t *testing.T) {
	data := &settingsMemory{}
	model, err := loadSettings(data)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "moved")
	if err := model.Update(func(v *SettingsValues) { v.DownloadDirectory = platform.LocalReference{Path: path} }); err != nil {
		t.Fatal(err)
	}
	if access, err := model.OpenDownloadDirectory(); err == nil || access != nil {
		t.Fatal("失效目录应要求重选，不能静默写入其他目录")
	}
	if model.Values().DownloadDirectory.Path != path {
		t.Fatal("无法访问时丢失了原选择")
	}
}
