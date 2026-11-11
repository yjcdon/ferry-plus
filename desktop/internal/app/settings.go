package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"reflect"
	"slices"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/egoist/mygo"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
	"github.com/yjcdon/ferry-drive/desktop/internal/store"
)

const (
	MaxDownloadFiles         = 10
	MaxUploadTasks           = 4
	MaxUploadParts           = 4
	MaxDownloadConnections   = 16
	TotalDownloadConnections = 20
)

type DiskSettings struct {
	TransferFolder       string `json:"transferFolder"`
	CleanupAfterDownload bool   `json:"cleanupAfterDownload"`
	ConnectionsPerFile   int    `json:"connectionsPerFile"`
}

type SettingsValues struct {
	DownloadDirectory            platform.LocalReference `json:"downloadDirectory"`
	MaxConcurrentFiles           int                     `json:"maxConcurrentFiles"`
	MaxConcurrentUploads         int                     `json:"maxConcurrentUploads"`
	UploadPartsPerFile           int                     `json:"uploadPartsPerFile"`
	UploadBytesPerSecond         int64                   `json:"uploadBytesPerSecond"`
	DownloadBytesPerSecond       int64                   `json:"downloadBytesPerSecond"`
	DetectsCopiedLinks           bool                    `json:"detectsCopiedLinks"`
	DisableAutomaticUpdateChecks bool                    `json:"disableAutomaticUpdateChecks,omitempty"`
	Baidu                        DiskSettings            `json:"baidu"`
	Quark                        DiskSettings            `json:"quark"`
	SelectedTab                  int                     `json:"selectedTab"`
}

func DefaultSettings() SettingsValues {
	return SettingsValues{
		MaxConcurrentFiles: 1, MaxConcurrentUploads: 1, UploadPartsPerFile: 1, DetectsCopiedLinks: true,
		Baidu: DiskSettings{TransferFolder: "/Ferry", CleanupAfterDownload: true, ConnectionsPerFile: 1},
		Quark: DiskSettings{TransferFolder: "/Ferry Plus", CleanupAfterDownload: true, ConnectionsPerFile: 1},
	}
}

func (s SettingsValues) Disk(provider Provider) DiskSettings {
	if provider == Baidu {
		return s.Baidu
	}
	return s.Quark
}

func (s SettingsValues) AllowedConcurrentFiles() int {
	return max(1, min(MaxDownloadFiles, TotalDownloadConnections/max(1, s.Baidu.ConnectionsPerFile, s.Quark.ConnectionsPerFile)))
}

func (s SettingsValues) AllowedConnections() int {
	return max(1, min(MaxDownloadConnections, TotalDownloadConnections/max(1, s.MaxConcurrentFiles)))
}

func (s *SettingsValues) normalize() {
	s.MaxConcurrentFiles = min(max(s.MaxConcurrentFiles, 1), MaxDownloadFiles)
	s.Baidu.ConnectionsPerFile = min(max(s.Baidu.ConnectionsPerFile, 1), s.AllowedConnections())
	s.Quark.ConnectionsPerFile = min(max(s.Quark.ConnectionsPerFile, 1), s.AllowedConnections())
	s.MaxConcurrentUploads = min(max(s.MaxConcurrentUploads, 1), MaxUploadTasks)
	s.UploadPartsPerFile = min(max(s.UploadPartsPerFile, 1), MaxUploadParts)
	s.UploadBytesPerSecond = max(0, s.UploadBytesPerSecond)
	s.DownloadBytesPerSecond = max(0, s.DownloadBytesPerSecond)
	s.Baidu.TransferFolder = normalizeTransferFolder(s.Baidu.TransferFolder, "/Ferry")
	s.Quark.TransferFolder = normalizeTransferFolder(s.Quark.TransferFolder, "/Ferry Plus")
	if s.SelectedTab < 0 || s.SelectedTab >= 5 {
		s.SelectedTab = 0
	}
}

func normalizeTransferFolder(input, fallback string) string {
	input = strings.TrimSpace(input)
	if input == "" {
		return fallback
	}
	components := strings.FieldsFunc(input, func(r rune) bool { return r == '/' })
	return "/" + strings.Join(components, "/")
}

type savedProxy struct {
	Config   platform.ProxySettings `json:"config"`
	Password string                 `json:"password,omitempty"`
}

// settingsStore allows tests to exercise settings without using the user's records.
type settingsStore interface {
	Read(string, any) error
	Write(string, any) error
	ReadCredential(string) ([]byte, error)
	WriteCredential(string, []byte) error
}

// SettingsModel publishes committed settings only after their record is saved.
// Business settings and proxy credentials have independent atomic records.
type SettingsModel struct {
	data   settingsStore
	write  sync.Mutex
	values atomic.Pointer[SettingsValues]
	proxy  atomic.Pointer[savedProxy]
}

// LoadSettings keeps defaults usable when a record cannot be restored and
// returns that failure for the settings window to show.
func LoadSettings(data *store.Store) (*SettingsModel, error) { return loadSettings(data) }

func loadSettings(data settingsStore) (*SettingsModel, error) {
	s := &SettingsModel{data: data}
	values := DefaultSettings()
	readErr := data.Read("settings", &values)
	if readErr != nil {
		values = DefaultSettings()
		if errors.Is(readErr, fs.ErrNotExist) {
			readErr = nil
		}
	}
	values.normalize()
	s.values.Store(&values)

	proxy := savedProxy{Config: platform.ProxySettings{Mode: platform.ProxySystem}}
	raw, proxyErr := data.ReadCredential("settings-proxy")
	if errors.Is(proxyErr, fs.ErrNotExist) {
		proxyErr = nil
	} else if proxyErr == nil {
		var restored savedProxy
		if proxyErr = json.Unmarshal(raw, &restored); proxyErr == nil {
			switch restored.Config.Mode {
			case platform.ProxySystem, platform.ProxySOCKS5:
				proxy = restored
			default:
				proxyErr = errors.New("代理模式无效。")
			}
		}
	}
	if proxyErr != nil {
		proxyErr = fmt.Errorf("读取代理设置：%w", proxyErr)
	}
	s.proxy.Store(&proxy)
	return s, errors.Join(readErr, proxyErr)
}

func (s *SettingsModel) Values() SettingsValues {
	values := *s.values.Load()
	values.DownloadDirectory.Bookmark = slices.Clone(values.DownloadDirectory.Bookmark)
	return values
}

func (s *SettingsModel) Proxy() (platform.ProxySettings, string) {
	value := s.proxy.Load()
	cfg := value.Config
	if cfg.Port != nil {
		port := *cfg.Port
		cfg.Port = &port
	}
	return cfg, value.Password
}

// Update changes a settings group without overwriting other concurrent saves.
func (s *SettingsModel) Update(update func(*SettingsValues)) error {
	s.write.Lock()
	defer s.write.Unlock()
	previous := s.values.Load()
	values := s.Values()
	update(&values)
	values.normalize()
	if reflect.DeepEqual(*previous, values) {
		return nil
	}
	if err := s.data.Write("settings", values); err != nil {
		return err
	}
	values.DownloadDirectory.Bookmark = slices.Clone(values.DownloadDirectory.Bookmark)
	s.values.Store(&values)
	return nil
}

// SetProxy saves the settings and their associated password together. The
// transport uses system settings while an incomplete SOCKS5 draft is saved.
func (s *SettingsModel) SetProxy(config platform.ProxySettings, password string) error {
	if config.Mode != platform.ProxySystem && config.Mode != platform.ProxySOCKS5 {
		return errors.New("代理模式无效。")
	}
	config.Host = strings.TrimSpace(config.Host)
	config.Username = strings.TrimSpace(config.Username)
	if config.Port != nil {
		port := *config.Port
		config.Port = &port
	}
	next := savedProxy{Config: config, Password: password}
	s.write.Lock()
	defer s.write.Unlock()
	if reflect.DeepEqual(*s.proxy.Load(), next) {
		return nil
	}
	data, err := json.Marshal(next)
	if err != nil {
		return err
	}
	if err := s.data.WriteCredential("settings-proxy", data); err != nil {
		return err
	}
	s.proxy.Store(&next)
	return nil
}

// OpenDownloadDirectory resolves the current selection. An inaccessible custom
// directory reports its own error so a job can ask for a new destination.
func (s *SettingsModel) OpenDownloadDirectory() (*platform.LocalAccess, error) {
	reference := s.Values().DownloadDirectory
	return openSettingsDirectory(reference)
}

// CheckDownloadDirectory restores a moved directory's path or renewed bookmark
// while the saved selection is still the same one.
func (s *SettingsModel) CheckDownloadDirectory(ctx context.Context) error {
	before := s.Values().DownloadDirectory
	if before.Path == "" {
		return nil
	}
	access, err := openSettingsDirectory(before)
	if err != nil {
		return err
	}
	defer access.Close()
	if err := ctx.Err(); err != nil {
		return err
	}
	if reflect.DeepEqual(before, access.Reference) {
		return nil
	}
	return s.Update(func(values *SettingsValues) {
		if reflect.DeepEqual(before, values.DownloadDirectory) {
			values.DownloadDirectory = access.Reference
		}
	})
}

func openSettingsDirectory(ref platform.LocalReference) (*platform.LocalAccess, error) {
	if ref.Path == "" {
		path, err := mygo.App.Path(mygo.PathDownloads)
		if err != nil {
			return nil, fmt.Errorf("定位系统下载目录：%w", err)
		}
		ref.Path = path
	}
	access, err := platform.OpenLocalItem(ref)
	if err != nil {
		return nil, fmt.Errorf("无法访问下载目录，请重新选择：%w", err)
	}
	root, err := os.OpenRoot(access.Reference.Path)
	if err != nil {
		access.Close()
		return nil, fmt.Errorf("请选择可访问的下载目录：%w", err)
	}
	root.Close()
	return access, nil
}
