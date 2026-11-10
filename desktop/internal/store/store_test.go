package store

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/egoist/mygo"
)

type memoryKeys struct {
	key []byte
	err error
}

func (k *memoryKeys) Get(string) ([]byte, error) {
	if k.err != nil {
		return nil, k.err
	}
	if k.key == nil {
		return nil, mygo.ErrSecretNotFound
	}
	return k.key, nil
}

func (k *memoryKeys) Set(_ string, value []byte) error {
	k.key = bytes.Clone(value)
	return nil
}

func openTest(t *testing.T, dir string, keys keyStore) *Store {
	t.Helper()
	s, err := open(dir, keys)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { check(t, s.Close()) })
	return s
}

func check(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func TestRecordRecovery(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir, &memoryKeys{})
	type checkpoint struct {
		Offset int64
		Paused bool
	}
	want := checkpoint{Offset: 2048, Paused: true}
	var got checkpoint
	if err := s.Read("download-1", &got); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("absent checkpoint: %v", err)
	}
	check(t, s.Write("download-1", checkpoint{Offset: 1024}))
	check(t, s.Write("download-1", want))
	// A process may leave an incomplete temporary write before replacement.
	check(t, os.WriteFile(filepath.Join(dir, ".write-interrupted"), []byte(`{"version":1,`), 0o600))
	check(t, s.Close())

	s = openTest(t, dir, &memoryKeys{})
	check(t, s.Read("download-1", &got))
	if got != want {
		t.Fatalf("restored checkpoint = %+v, want %+v", got, want)
	}
	if err := s.Write("download-1", make(chan int)); err == nil {
		t.Fatal("unencodable checkpoint was accepted")
	}
	got = checkpoint{}
	check(t, s.Read("download-1", &got))
	if got != want {
		t.Fatalf("failed write replaced the checkpoint: %+v", got)
	}
	check(t, os.WriteFile(filepath.Join(dir, "record-future.json"), []byte(`{"version":2,"value":{}}`), 0o600))
	if err := s.Read("future", &got); err == nil {
		t.Fatal("unknown record version was accepted")
	}
	if err := s.Read("../download-1", &got); !errors.Is(err, fs.ErrInvalid) {
		t.Fatalf("invalid record name: %v", err)
	}
}

func TestAtomicWriteFailure(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir, &memoryKeys{})
	check(t, os.Mkdir(filepath.Join(dir, "record-settings.json"), 0o700))
	if err := s.Write("settings", map[string]int{"files": 2}); err == nil {
		t.Fatal("replacing a directory reported success")
	}
	files, err := filepath.Glob(filepath.Join(dir, ".write-*"))
	check(t, err)
	if len(files) != 0 {
		t.Fatalf("failed write left temporary files: %v", files)
	}
}

func TestCredentialRecovery(t *testing.T) {
	dir := t.TempDir()
	keys := &memoryKeys{}
	s := openTest(t, dir, keys)
	name := "quark"
	want := bytes.Repeat([]byte("private-cookie-value "), 300)
	check(t, s.WriteCredential(name, want))
	check(t, s.Close())

	s = openTest(t, dir, keys)
	got, err := s.ReadCredential(name)
	check(t, err)
	if !bytes.Equal(got, want) {
		t.Fatal("credential changed after reopening")
	}
	path := filepath.Join(dir, "secret-"+name+".bin")
	sealed, err := os.ReadFile(path)
	check(t, err)
	if bytes.Contains(sealed, []byte("private-cookie-value")) {
		t.Fatal("credential appears in plaintext")
	}

	check(t, os.WriteFile(filepath.Join(dir, "secret-baidu.bin"), sealed, 0o600))
	if _, err := s.ReadCredential("baidu"); err == nil {
		t.Fatal("credential authenticated under the wrong record name")
	}
	check(t, s.RemoveCredential("baidu"))
	sealed[len(sealed)-1] ^= 1
	check(t, os.WriteFile(path, sealed, 0o600))
	if _, err := s.ReadCredential(name); err == nil {
		t.Fatal("modified credential authenticated")
	}

	keys.err = fs.ErrPermission
	if _, err := s.ReadCredential(name); !errors.Is(err, fs.ErrPermission) {
		t.Fatalf("credential store unavailable: %v", err)
	}
	keys.err, keys.key = nil, nil
	if err := s.WriteCredential(name, want); !errors.Is(err, mygo.ErrSecretNotFound) {
		t.Fatalf("missing key with saved credentials: %v", err)
	}
	if keys.key != nil {
		t.Fatal("lost credential key was replaced")
	}
	check(t, s.RemoveCredential(name))
	if _, err := s.ReadCredential(name); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("removed credential: %v", err)
	}
	check(t, s.WriteCredential(name, want))
}

func TestExclusiveWriter(t *testing.T) {
	if dir := os.Getenv("FERRY_STORE_TEST_DIR"); dir != "" {
		s, err := open(dir, &memoryKeys{})
		if os.Getenv("FERRY_STORE_TEST_BUSY") == "1" {
			if !errors.Is(err, ErrInUse) {
				t.Fatalf("second process should see the active writer: %v", err)
			}
			return
		}
		check(t, err)
		check(t, s.Write("settings", "saved"))
		os.Exit(0) // Leave the descriptor open so the OS must release the lock.
	}
	dir := t.TempDir()
	s := openTest(t, dir, &memoryKeys{})
	child := func(busy string) {
		t.Helper()
		cmd := exec.Command(os.Args[0], "-test.run=^TestExclusiveWriter$")
		cmd.Env = append(os.Environ(), "FERRY_STORE_TEST_DIR="+dir, "FERRY_STORE_TEST_BUSY="+busy)
		if output, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("writer subprocess: %v\n%s", err, output)
		}
	}
	child("1")
	check(t, s.Close())
	child("0")

	s = openTest(t, dir, &memoryKeys{})
	var got string
	check(t, s.Read("settings", &got))
	if got != "saved" {
		t.Fatalf("restored settings = %q", got)
	}
}
