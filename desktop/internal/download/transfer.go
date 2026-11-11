package download

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"
)

const checkpointInterval = 3 * time.Second

func segmentSize(size int64) int64 {
	switch {
	case size < 5<<20:
		return 256 << 10
	case size < 10<<20:
		return 512 << 10
	case size < 15<<20:
		return 1 << 20
	default:
		return 4 << 20
	}
}

func segmentCount(size, chunkSize int64) int64 {
	if size == 0 {
		return 0
	}
	return (size-1)/chunkSize + 1
}

func segmentBounds(index, size, chunkSize int64) (start, end int64) {
	start = index * chunkSize
	return start, start + min(chunkSize, size-start)
}

func (t *transfer) transfer(ctx context.Context, source *linkSource, connections int) error {
	size := t.record.Size
	if t.record.Full || size != 0 && t.done == size {
		return nil
	}
	if t.record.WholeBytes > 0 {
		t.report(t.record.WholeBytes)
		return errRangeUnsupported
	}

	chunkSize := segmentSize(size)
	total := segmentCount(size, chunkSize)
	first := int64(0)
	for t.record.Chunks[first] {
		first++
	}
	start, end := segmentBounds(first, size, chunkSize)
	response, err := source.get(ctx, start, end, size, t.record.Entity)
	if err != nil {
		return err
	}
	if response.StatusCode == http.StatusOK {
		return t.transferWhole(ctx, response)
	}
	data := make([]byte, end-start)
	responseEntity, err := rangeData(response, start, end, size, data)
	if err != nil {
		return err
	}
	if !t.record.Entity.matches(responseEntity) {
		return errRemoteChanged
	}
	if err := t.file.Truncate(size); err != nil {
		return err
	}
	if err := t.accept(first, start, data, responseEntity); err != nil {
		return err
	}
	if t.done == size {
		return nil
	}
	return t.transferRanges(ctx, source, min(connections, int(total-first-1)), first+1, total, chunkSize)
}

func (t *transfer) transferWhole(ctx context.Context, response *http.Response) error {
	defer response.Body.Close()
	size := t.record.Size
	if response.Header.Get("Content-Range") != "" ||
		response.ContentLength != -1 && response.ContentLength != size {
		return errors.New("完整下载响应的文件长度不一致")
	}
	current := responseEntity(response)
	if !t.record.Entity.matches(current) {
		return errRemoteChanged
	}
	if t.done != 0 {
		return errRangeUnsupported
	}
	if err := t.file.Truncate(0); err != nil {
		return err
	}
	if n, err := io.CopyN(wholeWriter{t}, contextReader{ctx, response.Body}, size); err != nil {
		return fmt.Errorf("完整下载响应只接收 %d / %d 字节: %w", n, size, err)
	}
	if err := expectEOF(response.Body); err != nil {
		return err
	}
	t.record.Entity.merge(current)
	t.record.Full = true
	t.record.WholeBytes = 0
	t.done = size
	t.dirty = true
	t.report(size)
	return nil
}

type wholeWriter struct{ *transfer }

func (w wholeWriter) Write(p []byte) (int, error) {
	n, err := w.file.Write(p)
	w.record.WholeBytes += int64(n)
	w.dirty = true
	w.report(w.record.WholeBytes)
	if err == nil && time.Since(w.saved) >= checkpointInterval {
		err = w.save()
	}
	return n, err
}

type segmentResult struct {
	index  int64
	data   []byte
	entity entity
	err    error
}

func (t *transfer) transferRanges(ctx context.Context, source *linkSource, connections int, first, total, chunkSize int64) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	jobs := make(chan int64)
	results := make(chan segmentResult)
	var workers sync.WaitGroup
	size, knownEntity := t.record.Size, t.record.Entity
	for range connections {
		workers.Go(func() {
			buffer := make([]byte, chunkSize)
			for index := range jobs {
				start, end := segmentBounds(index, size, chunkSize)
				data := buffer[:end-start]
				info, err := source.fetchRange(ctx, start, end, size, knownEntity, data)
				select {
				case results <- segmentResult{index, data, info, err}:
					// The coordinator writes data before it can send the next job.
				case <-ctx.Done():
					return
				}
			}
		})
	}
	defer func() {
		cancel()
		close(jobs)
		workers.Wait()
	}()

	for next := first; t.done != size; {
		for next < total && t.record.Chunks[next] {
			next++
		}
		var send chan<- int64
		if next < total {
			send = jobs
		}
		select {
		case send <- next:
			next++
		case result := <-results:
			if result.err != nil {
				return result.err
			}
			start, _ := segmentBounds(result.index, size, chunkSize)
			if err := t.accept(result.index, start, result.data, result.entity); err != nil {
				return err
			}
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return nil
}

func (t *transfer) accept(index, start int64, data []byte, remote entity) error {
	if !t.record.Entity.matches(remote) {
		return errRemoteChanged
	}
	if _, err := t.file.WriteAt(data, start); err != nil {
		return fmt.Errorf("写入下载分片: %w", err)
	}
	t.record.Entity.merge(remote)
	if t.record.Chunks == nil {
		t.record.Chunks = make(map[int64]bool)
	}
	t.record.Chunks[index] = true
	t.done += int64(len(data))
	t.dirty = true
	t.report(t.done)
	if time.Since(t.saved) >= checkpointInterval {
		return t.save()
	}
	return nil
}
