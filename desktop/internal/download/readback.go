package download

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net/http"
)

// ReadbackSHA256 verifies the bytes of a remote object without writing a local file.
// Each range uses the download link's normal refresh policy and feeds one digest.
func ReadbackSHA256(ctx context.Context, client *http.Client, resolve Resolve, size int64,
	wait func(context.Context, int) error, progress func(int64)) (string, error) {
	source := linkSource{client: client, resolve: resolve}
	digest := sha256.New()
	buffer := make([]byte, 128<<10)
	var previous entity
	for offset := int64(0); ; {
		end := offset + min(size-offset, 256<<10)
		response, err := source.get(ctx, offset, end, size, previous)
		if err != nil {
			return "", err
		}
		info := responseEntity(response)
		err = func() error {
			defer response.Body.Close()
			if !previous.matches(info) {
				return errRemoteChanged
			}
			if response.StatusCode == http.StatusOK && offset == 0 {
				// Some download hosts return the whole object on the first request.
				end = size
				if response.ContentLength >= 0 && response.ContentLength != size {
					return errors.New("上传回读长度与文件大小不一致")
				}
			} else if err := validateRange(response, offset, end, size); err != nil {
				return err
			}
			for done := offset; done < end; {
				length := int(min(end-done, int64(len(buffer))))
				if err := wait(ctx, length); err != nil {
					return err
				}
				if _, err := io.ReadFull(response.Body, buffer[:length]); err != nil {
					return err
				}
				digest.Write(buffer[:length])
				done += int64(length)
				progress(done)
			}
			return expectEOF(response.Body)
		}()
		if err != nil {
			return "", err
		}
		if end == size {
			return fmt.Sprintf("%x", digest.Sum(nil)), ctx.Err()
		}
		previous.merge(info)
		offset = end
	}
}
