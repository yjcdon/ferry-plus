package app

import (
	"context"
	"errors"
	"fmt"
	"sync"
)

type downloadedItem struct {
	index int
	item  TransferItem
	err   error
}

func downloadItemID(jobID string, index int) string {
	return fmt.Sprintf("%s-%d", jobID, index)
}

// Downloads run concurrently, while one collector writes each result before
// acknowledging its engine receipt. Cancellation stops dispatch and waits for
// in-flight files, so even a result committed during pause is not lost.
func (t *Transfers) runDownloadFiles(parent context.Context, worker *transferWorker, req savedDownload, items []TransferItem) error {
	pending := make([]int, 0, len(items))
	progress := make([]int64, len(items))
	live, total := transferTotals(items)
	for i, item := range items {
		if err := parent.Err(); err != nil {
			return err
		}
		file := req.Plan[i]
		if item.Remote != file.Entry.Ref || item.RelativePath != file.RelativePath || item.Size != file.Entry.Size {
			return errors.New("下载任务的项目身份与原清单不一致")
		}
		if !item.Complete {
			pending = append(pending, i)
			progress[i] = item.CheckpointBytes
		} else {
			progress[i] = item.Size
			if !item.Directory {
				if err := t.download.Acknowledge(downloadItemID(worker.job.ID, i)); err != nil {
					return err
				}
			}
		}
	}
	if len(pending) == 0 {
		return nil
	}
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	var progressMu sync.Mutex
	report := func(index int, bytes int64) {
		progressMu.Lock()
		defer progressMu.Unlock()
		live += bytes - progress[index]
		progress[index] = bytes
		t.report(worker, "downloading", live, total)
	}

	jobs := make(chan int)
	results := make(chan downloadedItem)
	var workers sync.WaitGroup
	workers.Go(func() {
		defer close(jobs)
		for _, i := range pending {
			select {
			case jobs <- i:
			case <-ctx.Done():
				return
			}
		}
	})
	for range min(MaxDownloadFiles, len(pending)) {
		workers.Go(func() {
			for i := range jobs {
				item := items[i]
				item.Error = ""
				err := t.runDownloadFile(ctx, worker, req, i, &item, func(bytes, _ int64) {
					report(i, bytes)
				})
				results <- downloadedItem{index: i, item: item, err: err}
			}
		})
	}
	go func() {
		workers.Wait()
		close(results)
	}()

	var firstErr, accountErr, barrierErr error
	firstFailed := len(items)
	for result := range results {
		if barrierErr != nil {
			continue // Engine receipts stay available for a retry.
		}
		i, item, err := result.index, result.item, result.err
		switch {
		case err == nil:
			item.Complete = true
			item.CheckpointBytes = 0
			report(i, item.Size)
		case ctx.Err() != nil:
			if item.CheckpointBytes == items[i].CheckpointBytes {
				continue
			}
			report(i, item.CheckpointBytes)
		case errors.Is(err, ErrDirectorySessionChanged) || isLoginExpired(worker.job.Provider, err):
			accountErr = err
			cancel()
			if item.CheckpointBytes == items[i].CheckpointBytes {
				continue
			}
			report(i, item.CheckpointBytes)
		default:
			report(i, item.CheckpointBytes)
			item.Error = err.Error()
			if i < firstFailed {
				firstFailed = i
				firstErr = fmt.Errorf("%s: %w", item.RelativePath, err)
			}
		}
		items[i] = item
		if err := t.saveDownload(worker, req, items); err != nil {
			barrierErr = err
			cancel()
			continue
		}
		if item.Complete && !item.Directory {
			if err := t.download.Acknowledge(downloadItemID(worker.job.ID, i)); err != nil {
				barrierErr = err
				cancel()
			}
		}
	}
	return errors.Join(barrierErr, accountErr, parent.Err(), firstErr)
}

func (t *Transfers) runDownloadFile(ctx context.Context, worker *transferWorker, req savedDownload, index int,
	item *TransferItem, progress func(int64, int64)) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := t.checkAccount(worker); err != nil {
		return err
	}
	file := req.Plan[index]
	connections := 0
	if !file.Entry.IsDirectory {
		var release func()
		var err error
		connections, release, err = t.takeDownloadSlot(ctx, worker.job.Provider)
		if err != nil {
			return err
		}
		defer release()
	}
	return t.downloadOne(ctx, worker, req.Folder, file, downloadItemID(worker.job.ID, index), connections, item, progress)
}
