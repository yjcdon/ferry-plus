package core

import (
	"context"
	"crypto/md5"
	"crypto/sha1"
	"crypto/sha256"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

type uploadLocalItem struct {
	Root        int
	Relative    string
	Inside      string
	Directory   bool
	Size        int64
	Modified    time.Time
	Replacement *platform.LocalReference `json:",omitempty"`
}

func scanUpload(ctx context.Context, sources []platform.LocalReference) ([]platform.LocalReference, []uploadLocalItem, error) {
	indices := make([]int, len(sources))
	for i := range indices {
		indices[i] = i
	}
	slices.SortStableFunc(indices, func(a, b int) int {
		return strings.Compare(filepath.Clean(sources[a].Path), filepath.Clean(sources[b].Path))
	})
	var directories []string
	seenPaths := make(map[string]bool)
	seenNames := make(map[string]bool)
	var entries []uploadLocalItem
	for _, i := range indices {
		if err := ctx.Err(); err != nil {
			return nil, nil, err
		}
		local := filepath.Clean(sources[i].Path)
		if seenPaths[local] || slices.ContainsFunc(directories, func(root string) bool {
			rel, err := filepath.Rel(root, local)
			return err == nil && filepath.IsLocal(rel)
		}) {
			continue
		}
		seenPaths[local] = true
		access, err := platform.OpenLocalItem(sources[i])
		if err != nil {
			return nil, nil, err
		}
		selected := access.Reference.Path
		name := filepath.Base(local)
		err = filepath.WalkDir(selected, func(file string, dir fs.DirEntry, readErr error) error {
			if readErr != nil {
				return readErr
			}
			if err := ctx.Err(); err != nil {
				return err
			}
			inside, err := filepath.Rel(selected, file)
			if err != nil {
				return err
			}
			relative := path.Join(name, filepath.ToSlash(inside))
			if name == "." || !fs.ValidPath(relative) || relative == "." || strings.ContainsRune(relative, 0) {
				return fmt.Errorf("上传源路径无效: %s", file)
			}
			info, err := dir.Info()
			if err != nil {
				return err
			}
			if !info.IsDir() && !info.Mode().IsRegular() {
				return fmt.Errorf("上传只支持普通文件和目录: %s", file)
			}
			if seenNames[relative] {
				return fmt.Errorf("所选内容中有重复相对路径: %s", relative)
			}
			seenNames[relative] = true
			item := uploadLocalItem{Root: i, Relative: relative, Inside: inside, Directory: info.IsDir(), Modified: info.ModTime()}
			if info.IsDir() && inside == "." {
				directories = append(directories, local)
			}
			if !info.IsDir() {
				item.Size = info.Size()
			}
			entries = append(entries, item)
			return nil
		})
		access.Close()
		if err != nil {
			return nil, nil, err
		}
	}
	return sources, entries, nil
}

type uploadSource struct {
	access *platform.LocalAccess
	dir    *os.Root
	file   *os.File
	path   string
	info   fs.FileInfo
}

func openUploadSource(source platform.LocalReference, entry uploadLocalItem) (*uploadSource, error) {
	access, err := platform.OpenLocalItem(source)
	if err != nil {
		return nil, err
	}
	file := &uploadSource{access: access, path: access.Reference.Path}
	ok := false
	defer func() {
		if !ok {
			file.close()
		}
	}()
	lstat := os.Lstat
	open := func(path string) (*os.File, error) { return os.OpenFile(path, uploadOpenFlags, 0) }
	if entry.Inside != "." {
		file.dir, err = os.OpenRoot(file.path)
		if err != nil {
			return nil, err
		}
		file.path, lstat = entry.Inside, file.dir.Lstat
		open = func(path string) (*os.File, error) { return file.dir.OpenFile(path, uploadOpenFlags, 0) }
	}
	info, err := lstat(file.path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() != entry.Size || !entry.Modified.IsZero() && !info.ModTime().Equal(entry.Modified) {
		return nil, ErrUploadSourceChanged
	}
	file.file, err = open(file.path)
	if err != nil {
		return nil, err
	}
	file.info = info
	if err := file.verify(); err != nil {
		return nil, err
	}
	ok = true
	return file, nil
}

func (s *uploadSource) close() {
	if s.file != nil {
		s.file.Close()
	}
	if s.dir != nil {
		s.dir.Close()
	}
	s.access.Close()
}

func (s *uploadSource) verify() error {
	lstat := os.Lstat
	if s.dir != nil {
		lstat = s.dir.Lstat
	}
	pathInfo, err := lstat(s.path)
	if err != nil {
		return err
	}
	fileInfo, err := s.file.Stat()
	if err != nil {
		return err
	}
	for _, info := range []fs.FileInfo{pathInfo, fileInfo} {
		if !info.Mode().IsRegular() || !os.SameFile(s.info, info) || info.Size() != s.info.Size() || !info.ModTime().Equal(s.info.ModTime()) {
			return ErrUploadSourceChanged
		}
	}
	return nil
}

func (s *uploadSource) readPart(ctx context.Context, offset int64, size int) ([]byte, error) {
	if err := s.verify(); err != nil {
		return nil, err
	}
	data := make([]byte, size)
	for at := 0; at < size; {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		n := min(1<<20, size-at)
		if _, err := s.file.ReadAt(data[at:at+n], offset+int64(at)); err != nil {
			return nil, err
		}
		at += n
	}
	return data, s.verify()
}

type uploadFingerprint struct {
	SHA256, MD5, SHA1, SliceMD5 string
	Parts                       []uploadPartDigest
	PartSize                    int
}

type uploadPartDigest struct {
	SHA256, MD5 string
}

func (s *uploadSource) fingerprint(ctx context.Context, partSize int) (uploadFingerprint, error) {
	size := s.info.Size()
	md5All, sha1All, shaAll, slice := md5.New(), sha1.New(), sha256.New(), md5.New()
	result := uploadFingerprint{PartSize: partSize}
	count := 1 + max(size-1, 0)/int64(partSize)
	buffer := make([]byte, min(1<<20, partSize))
	for part := int64(0); part < count; part++ {
		partMD5, partSHA := md5.New(), sha256.New()
		start := part * int64(partSize)
		end := min(size, start+int64(partSize))
		for offset := start; offset < end; {
			if err := ctx.Err(); err != nil {
				return uploadFingerprint{}, err
			}
			length := int(min(int64(len(buffer)), end-offset))
			chunk := buffer[:length]
			if _, err := s.file.ReadAt(chunk, offset); err != nil {
				return uploadFingerprint{}, err
			}
			md5All.Write(chunk)
			sha1All.Write(chunk)
			shaAll.Write(chunk)
			partMD5.Write(chunk)
			partSHA.Write(chunk)
			if offset < 256<<10 {
				slice.Write(chunk[:min(int64(length), (256<<10)-offset)])
			}
			offset += int64(length)
		}
		result.Parts = append(result.Parts, uploadPartDigest{MD5: fmt.Sprintf("%x", partMD5.Sum(nil)), SHA256: fmt.Sprintf("%x", partSHA.Sum(nil))})
	}
	result.MD5, result.SHA1, result.SHA256, result.SliceMD5 = fmt.Sprintf("%x", md5All.Sum(nil)), fmt.Sprintf("%x", sha1All.Sum(nil)),
		fmt.Sprintf("%x", shaAll.Sum(nil)), fmt.Sprintf("%x", slice.Sum(nil))
	return result, s.verify()
}

func uploadNameKey(name string) string {
	return norm.NFD.String(cases.Fold().String(norm.NFD.String(name)))
}

func uploadNumberedName(name string, number int) string {
	extension := path.Ext(name)
	if extension == name {
		extension = ""
	}
	return fmt.Sprintf("%s (%d)%s", strings.TrimSuffix(name, extension), number, extension)
}

type uploadPacer struct {
	shared func(context.Context, int) error
	rate   int64
	mu     sync.Mutex
	next   time.Time
}

func (p *uploadPacer) wait(ctx context.Context, size int) error {
	if p.shared != nil {
		return p.shared(ctx, size)
	}
	if p.rate == 0 || size == 0 {
		return ctx.Err()
	}
	p.mu.Lock()
	now := time.Now()
	if p.next.Before(now) {
		p.next = now
	}
	p.next = p.next.Add(time.Duration(float64(time.Second) * float64(size) / float64(p.rate)))
	delay := p.next.Sub(now)
	p.mu.Unlock()
	return waitUpload(ctx, delay)
}

func waitUpload(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

type uploadPartResult[T any] struct {
	receipt T
	err     error
}

// sendUploadParts keeps at most one bounded part per worker. The caller
// persists receipts serially even when an in-flight peer fails or pauses.
func sendUploadParts[T any](ctx context.Context, missing []int, parallel int, send func(context.Context, int) (T, error),
	record func(T) error,
) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	results := make(chan uploadPartResult[T], parallel)
	launch := func(index int) {
		go func() {
			receipt, err := send(ctx, index)
			results <- uploadPartResult[T]{receipt, err}
		}()
	}
	active := min(len(missing), parallel)
	for _, index := range missing[:active] {
		launch(index)
	}
	next := active
	var failure error
	for active > 0 {
		result := <-results
		active--
		err := result.err
		if err == nil {
			err = record(result.receipt)
		}
		if err == nil {
			err = ctx.Err()
		}
		if err != nil && failure == nil {
			failure = err
			cancel()
		}
		if failure == nil && next < len(missing) {
			launch(missing[next])
			next++
			active++
		}
	}
	if failure != nil {
		return failure
	}
	return ctx.Err()
}

func readUploadBytes(ctx context.Context, source *uploadSource, fingerprint uploadFingerprint, index int) ([]byte, error) {
	start := int64(index) * int64(fingerprint.PartSize)
	length := int(min(int64(fingerprint.PartSize), source.info.Size()-start))
	body, err := source.readPart(ctx, start, length)
	if err != nil {
		return nil, err
	}
	if fmt.Sprintf("%x", sha256.Sum256(body)) != fingerprint.Parts[index].SHA256 {
		return nil, ErrUploadSourceChanged
	}
	return body, nil
}
