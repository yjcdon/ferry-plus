// Package store owns Ferry Drive 5.0's local records and the task writer lock.
package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/egoist/mygo"
)

const recordVersion = 1

// ErrInUse means another process already owns this data directory.
var ErrInUse = errors.New("Ferry Drive 数据目录正在使用")

type keyStore interface {
	Get(name string) ([]byte, error)
	Set(name string, value []byte) error
}

// Store serializes writes for the lifetime of an exclusive OS file lock.
type Store struct {
	mu   sync.Mutex
	dir  string
	lock *os.File
	keys keyStore
}

// Open claims Ferry Drive 5.0's independent data directory. Close it after
// all task workers have finished writing.
func Open() (*Store, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return nil, fmt.Errorf("定位应用数据目录: %w", err)
	}
	return open(filepath.Join(base, "Ferry Drive", "v5"), mygo.Secrets.Service("io.github.yjcdon.FerryDrive.v5"))
}

func open(dir string, keys keyStore) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("创建数据目录: %w", err)
	}
	file, err := acquireLock(filepath.Join(dir, ".writer.lock"))
	if err != nil {
		return nil, fmt.Errorf("锁定数据目录: %w", err)
	}
	return &Store{dir: dir, lock: file, keys: keys}, nil
}

// Close releases the writer lock. The lock file stays in place so that
// subsequent processes always lock the same file.
func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.lock == nil {
		return nil
	}
	err := s.lock.Close()
	s.lock = nil
	if err != nil {
		return fmt.Errorf("释放数据目录锁: %w", err)
	}
	return nil
}

type record struct {
	Version int             `json:"version"`
	Value   json.RawMessage `json:"value"`
}

// Read restores a versioned record. A missing record returns fs.ErrNotExist
// through errors.Is. The caller discards the output on decoding failure.
func (s *Store) Read(name string, dst any) error {
	return s.withRecord("读取", "record-", name, ".json", func(path string) error {
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var envelope record
		if err := json.Unmarshal(data, &envelope); err != nil {
			return err
		}
		if envelope.Version != recordVersion {
			return fmt.Errorf("不支持的记录版本 %d", envelope.Version)
		}
		if len(envelope.Value) == 0 || string(envelope.Value) == "null" {
			return errors.New("记录缺少有效内容")
		}
		return json.Unmarshal(envelope.Value, dst)
	})
}

// Write commits a settings, task or checkpoint record by replacing its file.
// For downloads the worker syncs the partial file before saving its checkpoint.
func (s *Store) Write(name string, value any) error {
	return s.withRecord("保存", "record-", name, ".json", func(path string) error {
		raw, err := json.Marshal(value)
		if err != nil {
			return err
		}
		if string(raw) == "null" {
			return errors.New("记录缺少有效内容")
		}
		data, err := json.Marshal(record{Version: recordVersion, Value: raw})
		if err != nil {
			return err
		}
		return writeAtomic(path, data)
	})
}

// Remove clears a record. Removing an absent record succeeds.
func (s *Store) Remove(name string) error {
	return s.withRecord("删除", "record-", name, ".json", removeRecord)
}

func (s *Store) withRecord(operation, prefix, name, suffix string, run func(string) error) error {
	if !validName(name) {
		return fmt.Errorf("记录名称须使用 1～120 个小写字母、数字、连字符或下划线: %w", fs.ErrInvalid)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.lock == nil {
		return fs.ErrClosed
	}
	if err := run(filepath.Join(s.dir, prefix+name+suffix)); err != nil {
		return fmt.Errorf("%s记录 %q: %w", operation, name, err)
	}
	return nil
}

func validName(name string) bool {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789-_"
	return len(name) > 0 && len(name) <= 120 &&
		strings.IndexFunc(name, func(r rune) bool { return !strings.ContainsRune(alphabet, r) }) == -1
}

func writeAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	file, err := os.CreateTemp(dir, ".write-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, err = file.Write(data)
	if err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return replaceFile(file.Name(), path)
}

func removeRecord(path string) error {
	if err := os.Remove(path); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		return err
	}
	return syncDirectory(filepath.Dir(path))
}
