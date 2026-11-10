package core

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"slices"
	"strings"

	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
)

type uploadContentEntry struct {
	Directory bool   `json:"directory"`
	Path      string `json:"path"`
	SHA256    string `json:"sha256,omitempty"`
	Size      int64  `json:"size"`
}

// prepareContent establishes the original byte basis before any cloud write.
// Partial local failures are reported per file and never produce a signature.
func (u *uploadRun) prepareContent(ctx context.Context, manifest *uploadManifest, key string) (map[string]error, error) {
	if manifest.Signature != "" {
		return nil, nil
	}
	var failed map[string]error
	var content []uploadContentEntry
	complete := true
	started := manifest.RemoteStarted
	for _, entry := range manifest.Entries {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		itemKey := uploadItemKey(key, entry.Relative)
		var state uploadItemState
		if err := u.records.Read(itemKey, &state); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return nil, err
		}
		hasRemote := state.Intent != "" || state.Remote.identified() || state.Baidu != nil || state.Quark != nil
		started = started || hasRemote
		if !entry.Directory && state.Fingerprint.SHA256 == "" {
			if !hasRemote && !state.Complete && !state.Skipped {
				u.report(entry, "preparing", 0)
				source, err := uploadSourceFor(*manifest, &entry)
				if err != nil {
					return nil, err
				}
				basis, err := fingerprintUploadSource(ctx, source, entry)
				if err != nil {
					if ctx.Err() != nil {
						return nil, ctx.Err()
					}
					if failed == nil {
						failed = make(map[string]error)
					}
					failed[entry.Relative] = err
				} else {
					state.Fingerprint = basis
					if err := u.records.Write(itemKey, state); err != nil {
						return nil, err
					}
				}
			}
			complete = complete && state.Fingerprint.SHA256 != ""
		}
		content = append(content, uploadContentEntry{Directory: entry.Directory, Path: entry.Relative,
			SHA256: state.Fingerprint.SHA256, Size: entry.Size})
	}
	if complete {
		signature, err := uploadContentSignature(content)
		if err != nil {
			return nil, err
		}
		manifest.Signature = signature
	}
	if manifest.Signature != "" || started != manifest.RemoteStarted {
		manifest.RemoteStarted = started
		if err := u.records.Write(key, *manifest); err != nil {
			return nil, err
		}
	}
	return failed, nil
}

func uploadSourceFor(manifest uploadManifest, entry *uploadLocalItem) (platform.LocalReference, error) {
	if entry.Root < 0 || entry.Root >= len(manifest.Sources) {
		return platform.LocalReference{}, errors.New("上传源恢复记录无效")
	}
	if entry.Replacement != nil {
		entry.Inside = "."
		return *entry.Replacement, nil
	}
	return manifest.Sources[entry.Root], nil
}

func fingerprintUploadSource(ctx context.Context, ref platform.LocalReference, entry uploadLocalItem) (uploadFingerprint, error) {
	source, err := openUploadSource(ref, entry)
	if err != nil {
		return uploadFingerprint{}, err
	}
	defer source.close()
	return source.fingerprint(ctx, baidu.UploadPartSize)
}

func sameUploadDigest(a, b uploadFingerprint) bool {
	return a.SHA256 == b.SHA256 && a.MD5 == b.MD5 && a.SHA1 == b.SHA1
}

func uploadContentSignature(content []uploadContentEntry) (string, error) {
	slices.SortFunc(content, func(a, b uploadContentEntry) int { return strings.Compare(a.Path, b.Path) })
	var document bytes.Buffer
	encoder := json.NewEncoder(&document)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(content); err != nil {
		return "", err
	}
	hash := sha256.New()
	hash.Write([]byte("FerryUploadContent/v1\n"))
	hash.Write(bytes.TrimSuffix(document.Bytes(), []byte("\n")))
	return fmt.Sprintf("%x", hash.Sum(nil)), nil
}
