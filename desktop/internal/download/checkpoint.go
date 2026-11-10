package download

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func (t *transfer) restore(req Request, rel string) error {
	err := t.records.Read(t.name, &t.record)
	if errors.Is(err, fs.ErrNotExist) {
		t.record = checkpoint{
			Target: rel, Folder: filepath.Clean(req.Folder.Path), Size: req.Size, MD5: req.ExpectedMD5, SHA256: req.ExpectedSHA256,
			Partial: ".ferry-" + strings.ToLower(rand.Text()) + ".part",
		}
		return t.records.Write(t.name, t.record)
	}
	if err != nil {
		return err
	}
	c := t.record
	if c.Target != rel || c.Folder != filepath.Clean(req.Folder.Path) || c.Size != req.Size || c.MD5 != req.ExpectedMD5 || c.SHA256 != req.ExpectedSHA256 ||
		!localName(c.Partial) || !strings.HasPrefix(c.Partial, ".ferry-") || !strings.HasSuffix(c.Partial, ".part") ||
		c.Candidate != "" && !localName(c.Candidate) || c.Published && c.Candidate == "" ||
		c.WholeBytes < 0 || c.WholeBytes > c.Size || c.WholeBytes > 0 && (c.Full || len(c.Chunks) != 0) {
		return errors.New("下载断点与当前文件不一致")
	}
	if c.Full {
		t.done = c.Size
	} else {
		chunkSize := segmentSize(c.Size)
		for index, done := range c.Chunks {
			if !done || index < 0 || index >= segmentCount(c.Size, chunkSize) {
				return errors.New("下载断点包含无效分片")
			}
			start, end := segmentBounds(index, c.Size, chunkSize)
			t.done += end - start
		}
	}
	if c.Candidate != "" && (t.done != c.Size || c.Size == 0 && !c.Full) {
		return errors.New("下载断点缺少已发布文件的完整内容")
	}
	return nil
}

func localName(name string) bool {
	return filepath.IsLocal(name) && filepath.Base(name) == name && name != "."
}

func (t *transfer) openPartial() error {
	info, err := t.dir.Lstat(t.record.Partial)
	switch {
	case errors.Is(err, fs.ErrNotExist) && t.done == 0 && t.record.WholeBytes == 0 && t.record.Candidate == "":
		t.file, err = t.dir.OpenFile(t.record.Partial, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o600)
	case err != nil:
	case !info.Mode().IsRegular():
		return errors.New("下载临时路径不是普通文件")
	case t.done != 0 && info.Size() != t.record.Size:
		return errors.New("下载临时文件长度与断点不一致")
	default:
		t.file, err = t.dir.OpenFile(t.record.Partial, os.O_RDWR, 0)
	}
	if err != nil {
		return fmt.Errorf("打开下载临时文件: %w", err)
	}
	return nil
}

func (t *transfer) save() error {
	if !t.dirty {
		return nil
	}
	if err := t.file.Sync(); err != nil {
		return fmt.Errorf("刷盘保存下载内容: %w", err)
	}
	if err := t.records.Write(t.name, t.record); err != nil {
		return err
	}
	t.saved = time.Now()
	t.dirty = false
	return nil
}

func (t *transfer) report(done int64) {
	if t.progress != nil {
		t.progress(done, t.record.Size)
	}
}

// fileStamp identifies a renamed temporary file without trusting its name
// alone when the process exits before the completion receipt is written.
type fileStamp struct {
	Inode    uint64 `json:"inode"`
	Volume   uint64 `json:"volume,omitempty"`
	Birth    int64  `json:"birth"`
	Modified int64  `json:"modified"`
}

func (t *transfer) publish(ctx context.Context, base string) (string, error) {
	info, err := t.dir.Lstat(t.record.Partial)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Size() != t.record.Size {
		return "", errors.New("下载临时文件与发布记录不一致")
	}
	ext := filepath.Ext(base)
	if ext == base || ext == "." {
		ext = ""
	}
	stem := strings.TrimSuffix(base, ext)
	for ordinal := 0; ; ordinal++ {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		candidate := t.record.Candidate
		if candidate == "" {
			candidate = base
			if ordinal > 0 {
				candidate = fmt.Sprintf("%s (%d)%s", stem, ordinal, ext)
			}
			t.record.Candidate = candidate
			t.record.Stamp, err = publicationStamp(t.dir, t.record.Partial, info)
			if err != nil {
				return "", err
			}
			if err := t.records.Write(t.name, t.record); err != nil {
				return "", err
			}
		}

		stamp, err := publishExclusive(t.dir, t.record.Partial, candidate, t.record.Stamp)
		if errors.Is(err, fs.ErrExist) {
			existing, statErr := t.dir.Lstat(candidate)
			if statErr != nil {
				return "", statErr
			}
			if t.record.Stamp != nil || !os.SameFile(info, existing) {
				t.record.Candidate = ""
				continue
			}
		} else if err != nil {
			return "", fmt.Errorf("发布下载文件: %w", err)
		}
		if stamp == nil {
			stamp, err = t.publishedStamp()
			if err != nil {
				return "", err
			}
		}
		return t.completePublication(stamp)
	}
}

func (t *transfer) recoverPublication() (string, error) {
	stamp, err := t.publishedStamp()
	if err != nil {
		return "", err
	}
	if stamp == nil || *stamp != *t.record.Stamp {
		return "", errors.New("无法确认下载文件是否已发布，已保留现有文件")
	}
	return t.completePublication(stamp)
}

func (t *transfer) completePublication(stamp *fileStamp) (string, error) {
	if err := syncPublishDirectory(t.dir); err != nil {
		return "", fmt.Errorf("刷盘保存下载路径: %w", err)
	}
	t.record.Published = true
	t.record.Stamp = stamp
	if err := t.records.Write(t.name, t.record); err != nil {
		return "", err
	}
	return t.finish()
}

func (t *transfer) finish() (string, error) {
	info, err := t.publishedFileInfo()
	if err != nil {
		return "", err
	}
	if stamp := t.record.Stamp; stamp != nil {
		actual, err := publicationStamp(t.dir, t.record.Candidate, info)
		if err != nil {
			return "", err
		}
		if actual == nil || *actual != *stamp {
			return "", errors.New("已发布文件与下载记录不一致")
		}
	}
	partial, err := t.dir.Lstat(t.record.Partial)
	if errors.Is(err, fs.ErrNotExist) {
		return t.record.Candidate, nil
	}
	if err != nil {
		return "", err
	}
	if !os.SameFile(info, partial) {
		return "", errors.New("已发布文件和临时文件不一致")
	}
	if err := t.dir.Remove(t.record.Partial); err != nil {
		return "", fmt.Errorf("清理下载临时文件: %w", err)
	}
	return t.record.Candidate, nil
}

func (t *transfer) publishedStamp() (*fileStamp, error) {
	info, err := t.publishedFileInfo()
	if err != nil {
		return nil, err
	}
	return publicationStamp(t.dir, t.record.Candidate, info)
}

func (t *transfer) publishedFileInfo() (os.FileInfo, error) {
	info, err := t.dir.Lstat(t.record.Candidate)
	if err != nil {
		return nil, fmt.Errorf("查找已发布的下载文件: %w", err)
	}
	if !info.Mode().IsRegular() || info.Size() != t.record.Size {
		return nil, errors.New("已发布文件与下载记录不一致")
	}
	return info, nil
}
