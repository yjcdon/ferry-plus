package store

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/egoist/mygo"
)

const (
	keyName           = "record-key"
	keySize           = 32
	credentialPrefix  = "secret-"
	credentialSuffix  = ".bin"
	credentialVersion = 1
)

// ReadCredential decrypts the complete credential. An absent record, an
// unavailable key, and corrupted ciphertext are distinct results.
func (s *Store) ReadCredential(name string) ([]byte, error) {
	var plain []byte
	err := s.withRecord("读取凭据", credentialPrefix, name, credentialSuffix, func(path string) error {
		sealed, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if len(sealed) == 0 || sealed[0] != credentialVersion {
			return errors.New("凭据记录版本无效")
		}
		aead, err := s.credentialCipher(false)
		if err != nil {
			return err
		}
		plain, err = aead.Open(nil, nil, sealed[1:], []byte(name))
		if err != nil {
			return fmt.Errorf("凭据记录无法验证: %w", err)
		}
		return nil
	})
	return plain, err
}

// WriteCredential encrypts account cookies, proxy passwords, or upload
// secrets using the 5.0 key kept in the OS credential store.
func (s *Store) WriteCredential(name string, value []byte) error {
	return s.withRecord("保存凭据", credentialPrefix, name, credentialSuffix, func(path string) error {
		aead, err := s.credentialCipher(true)
		if err != nil {
			return err
		}
		return writeAtomic(path, aead.Seal([]byte{credentialVersion}, nil, value, []byte(name)))
	})
}

// RemoveCredential clears the encrypted record without accessing its key.
// An absent record counts as already removed.
func (s *Store) RemoveCredential(name string) error {
	return s.withRecord("删除凭据", credentialPrefix, name, credentialSuffix, removeRecord)
}

func (s *Store) credentialCipher(create bool) (cipher.AEAD, error) {
	key, err := s.keys.Get(keyName)
	if create && errors.Is(err, mygo.ErrSecretNotFound) {
		key, err = s.createCredentialKey()
	}
	if err != nil {
		return nil, fmt.Errorf("获取系统凭据密钥: %w", err)
	}
	if len(key) != keySize {
		return nil, errors.New("系统凭据密钥长度无效")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCMWithRandomNonce(block)
}

func (s *Store) createCredentialKey() ([]byte, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), credentialPrefix) && strings.HasSuffix(entry.Name(), credentialSuffix) {
			return nil, fmt.Errorf("已有凭据记录，系统密钥缺失: %w", mygo.ErrSecretNotFound)
		}
	}
	key := make([]byte, keySize)
	if _, err := rand.Read(key); err != nil {
		return nil, err
	}
	if err := s.keys.Set(keyName, key); err != nil {
		return nil, fmt.Errorf("保存系统凭据密钥: %w", err)
	}
	return key, nil
}
