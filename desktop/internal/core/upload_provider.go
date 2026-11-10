package core

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"path"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
	"github.com/yjcdon/ferry-drive/desktop/internal/platform"
	"github.com/yjcdon/ferry-drive/desktop/internal/quark"
)

func (u *uploadRun) chooseName(ctx context.Context, parent uploadRemoteItem, name string, directory bool) (string, uploadRemoteItem, bool, error) {
	if err := u.checkParent(ctx, parent); err != nil {
		return "", uploadRemoteItem{}, false, err
	}
	children, err := u.listDirectory(ctx, parent)
	if err != nil {
		return "", uploadRemoteItem{}, false, err
	}
	used := make(map[string]uploadRemoteItem, len(children))
	for _, item := range children {
		used[uploadNameKey(item.Name)] = item
	}
	current, exists := used[uploadNameKey(name)]
	switch {
	case !exists:
		return name, uploadRemoteItem{}, false, nil
	case current.Directory && directory:
		return current.Name, current, false, nil
	case u.req.ConflictPolicy == UploadSkip:
		return name, uploadRemoteItem{}, true, nil
	}
	for number := 1; ; number++ {
		candidate := uploadNumberedName(name, number)
		if _, exists := used[uploadNameKey(candidate)]; !exists {
			return candidate, uploadRemoteItem{}, false, nil
		}
	}
}

func (u *uploadRun) listDirectory(ctx context.Context, parent uploadRemoteItem) ([]uploadRemoteItem, error) {
	var items []uploadRemoteItem
	if u.req.Target.Provider == "baidu" {
		list, err := u.providers.Baidu.ListDirectory(ctx, parent.Path)
		if err != nil {
			return nil, err
		}
		for _, entry := range list {
			items = append(items, baiduUploadItem(entry))
		}
	} else {
		list, err := u.providers.Quark.ListDirectory(ctx, parent.FID)
		if err != nil {
			return nil, err
		}
		for _, entry := range list {
			items = append(items, uploadRemoteItem{Name: entry.Name, FID: entry.FID, Size: entry.Size, Directory: entry.IsDirectory})
		}
	}
	return items, nil
}

func (u *uploadRun) checkParent(ctx context.Context, parent uploadRemoteItem) error {
	if u.req.Target.Provider != "baidu" || parent.Path == "/" && parent.FSID == 0 {
		return ctx.Err()
	}
	if !parent.Directory || parent.FSID <= 0 {
		return errors.New("上传目标目录身份无效")
	}
	entries, err := u.providers.Baidu.ListDirectory(ctx, path.Dir(parent.Path))
	if err != nil {
		return err
	}
	for _, item := range entries {
		if item.Path == parent.Path && item.FSID == parent.FSID && item.IsDirectory {
			return nil
		}
	}
	return errors.New("目标目录已变化或被删除，请重新选择上传目录")
}

func (u *uploadRun) createDirectory(ctx context.Context, parent uploadRemoteItem, name string) (uploadRemoteItem, error) {
	if u.req.Target.Provider == "baidu" {
		entry, err := u.providers.Baidu.CreateOwnedDirectory(ctx, path.Join(parent.Path, name))
		return baiduUploadItem(entry), err
	}
	fid, err := u.providers.Quark.CreateDirectory(ctx, name, parent.FID)
	return uploadRemoteItem{Name: name, FID: fid, Directory: true}, err
}

func baiduUploadItem(entry baidu.Entry) uploadRemoteItem {
	return uploadRemoteItem{Name: entry.Name, Path: entry.Path, FSID: entry.FSID, Size: entry.Size, Directory: entry.IsDirectory}
}

func (u *uploadRun) uploadBaidu(ctx context.Context, entry uploadLocalItem, ref platform.LocalReference,
	parent uploadRemoteItem, state *uploadItemState, save func() error,
) error {
	if err := u.checkParent(ctx, parent); err != nil {
		return err
	}
	remotePath := path.Join(parent.Path, state.Name)
	var source *uploadSource
	defer func() {
		if source != nil {
			source.close()
		}
	}()
	open := func() error {
		if source == nil {
			var err error
			source, err = openUploadSource(ref, entry)
			return err
		}
		return nil
	}
	if state.Fingerprint.SHA256 == "" {
		if err := open(); err != nil {
			return err
		}
		fingerprint, err := source.fingerprint(ctx, baidu.UploadPartSize)
		if err != nil {
			return err
		}
		state.Fingerprint = fingerprint
		if err := save(); err != nil {
			return err
		}
	}
	baseline := state.Fingerprint
	if state.Baidu == nil {
		hashes := make([]string, 0, len(baseline.Parts))
		for _, part := range baseline.Parts {
			hashes = append(hashes, part.MD5)
		}
		if err := markUploadIntent(ctx, state, "baidu-prepare", save); err != nil {
			return err
		}
		preparation, err := u.providers.Baidu.PrepareUpload(ctx, remotePath, entry.Size, hashes, baseline.MD5, baseline.SliceMD5)
		if err != nil {
			return clearDefinitiveBaiduFailure(state, save, err)
		}
		state.Intent = ""
		if preparation.Instant != nil {
			state.Remote = baiduUploadItem(*preparation.Instant)
			return save()
		}
		state.Baidu = preparation.Session
		if err := save(); err != nil {
			return err
		}
	}
	session := *state.Baidu
	if session.Path != remotePath || session.Size != entry.Size || baseline.PartSize != baidu.UploadPartSize ||
		len(session.BlockMD5s) != len(baseline.Parts) {
		return errors.New("百度上传会话与原任务不一致")
	}
	if !state.BaiduRapidTried && u.req.ConflictPolicy == UploadKeepBoth && entry.Size > baidu.RapidProofLength && len(state.BaiduParts) == 0 {
		if err := open(); err != nil {
			return err
		}
		uk, err := strconv.ParseInt(u.req.Target.AccountID, 10, 64)
		if err != nil || uk <= 0 {
			return baidu.ErrUploadAccountChanged
		}
		result, err := u.providers.Baidu.RapidUpload(ctx, session, uk, baseline.MD5, baseline.SliceMD5,
			func(length int) error {
				if err := u.upload.wait(ctx, length); err != nil {
					return err
				}
				return markUploadIntent(ctx, state, "baidu-rapid", save)
			}, func(offset int64, length int) ([]byte, error) { return source.readPart(ctx, offset, length) })
		if err != nil {
			return clearDefinitiveBaiduFailure(state, save, err)
		}
		state.BaiduRapidTried, state.Intent = true, ""
		if result != nil {
			state.Remote = baiduUploadItem(*result)
			state.Name = result.Name
		}
		if err := save(); err != nil || state.Remote.identified() {
			return err
		}
	}
	confirmed := make(map[int]bool, len(state.BaiduParts))
	var done int64 = entry.Size
	for _, index := range session.PendingParts {
		done -= uploadPartLength(entry.Size, baseline.PartSize, index)
	}
	for _, receipt := range state.BaiduParts {
		if confirmed[receipt.Index] || !slices.Contains(session.PendingParts, receipt.Index) ||
			int64(receipt.Size) != uploadPartLength(entry.Size, baseline.PartSize, receipt.Index) ||
			!strings.EqualFold(receipt.MD5, baseline.Parts[receipt.Index].MD5) {
			return errors.New("百度分片恢复回执无效")
		}
		confirmed[receipt.Index] = true
		done += int64(receipt.Size)
	}
	var missing []int
	for _, index := range session.PendingParts {
		if !confirmed[index] {
			missing = append(missing, index)
		}
	}
	if len(missing) != 0 {
		if err := open(); err != nil {
			return err
		}
	}
	u.report(entry, "uploading", done)
	if err := sendUploadParts(ctx, missing, u.req.ParallelParts, func(ctx context.Context, index int) (baidu.UploadPartReceipt, error) {
		return uploadPart(ctx, source, baseline, entry.Size, index, &u.upload,
			func(data []byte) (baidu.UploadPartReceipt, error) {
				return u.providers.Baidu.UploadPart(ctx, data, index, session)
			})
	}, func(receipt baidu.UploadPartReceipt) error {
		state.BaiduParts = append(state.BaiduParts, receipt)
		if err := save(); err != nil {
			return err
		}
		done += int64(receipt.Size)
		u.report(entry, "uploading", done)
		return source.verify()
	}); err != nil {
		return err
	}
	if err := u.checkParent(ctx, parent); err != nil {
		return err
	}
	u.report(entry, "committing", done)
	if err := markUploadIntent(ctx, state, "baidu-merge", save); err != nil {
		return err
	}
	remote, err := u.providers.Baidu.CompleteUpload(ctx, session, state.BaiduParts)
	if err != nil {
		return clearDefinitiveBaiduFailure(state, save, err)
	}
	state.Remote, state.Intent = baiduUploadItem(remote), ""
	return save()
}

func clearDefinitiveBaiduFailure(state *uploadItemState, save func() error, err error) error {
	if state.Intent == "" {
		return err
	}
	var api baidu.APIError
	if errors.Is(err, baidu.ErrMissingBDUSS) || errors.Is(err, baidu.ErrMissingSTOKEN) || errors.Is(err, baidu.ErrLoginExpired) ||
		errors.Is(err, baidu.ErrLoginStateMissing) || errors.Is(err, baidu.ErrSecurityVerification) ||
		errors.Is(err, baidu.ErrAlreadyExists) || errors.Is(err, baidu.ErrInvalidFileName) ||
		errors.Is(err, baidu.ErrInvalidNameOrAccessDenied) || errors.Is(err, baidu.ErrAccessDenied) ||
		errors.Is(err, baidu.ErrUnauthorized) || errors.As(err, &api) && api.Code == -10 {
		state.Intent = ""
		return errors.Join(err, save())
	}
	return err
}

func (u *uploadRun) uploadQuark(ctx context.Context, key string, entry uploadLocalItem, ref platform.LocalReference,
	parent uploadRemoteItem, state *uploadItemState, save func() error,
) error {
	var source *uploadSource
	defer func() {
		if source != nil {
			source.close()
		}
	}()
	open := func() error {
		if source == nil {
			var err error
			source, err = openUploadSource(ref, entry)
			return err
		}
		return nil
	}
	var auth quark.UploadAuthorization
	if state.Quark == nil {
		if err := open(); err != nil {
			return err
		}
		if err := markUploadIntent(ctx, state, "quark-prepare", save); err != nil {
			return err
		}
		prepared, err := u.providers.Quark.PrepareUpload(ctx, state.Name, parent.FID, entry.Size, entry.Modified, entry.Modified)
		if err != nil {
			var rejected *quark.ServiceError
			if errors.As(err, &rejected) || errors.Is(err, quark.ErrLoginExpired) {
				state.Intent = ""
				return errors.Join(err, save())
			}
			return err
		}
		secret, err := prepared.Authorization.Encoded()
		if err != nil {
			return err
		}
		if err := u.records.WriteCredential(key, secret); err != nil {
			return err
		}
		state.Quark, state.Intent, auth = &prepared.Session, "", prepared.Authorization
		if err := save(); err != nil {
			return err
		}
	} else {
		secret, err := u.records.ReadCredential(key)
		if err != nil {
			return err
		}
		auth, err = quark.DecodeUploadAuthorization(secret)
		if err != nil {
			return err
		}
	}
	session := *state.Quark
	if session.ParentFID != parent.FID || session.Size != entry.Size || session.Name != state.Name {
		return errors.New("夸克上传会话与原任务不一致")
	}
	if state.Fingerprint.SHA256 == "" {
		if err := open(); err != nil {
			return err
		}
		fingerprint, err := source.fingerprint(ctx, session.PartSize)
		if err != nil {
			return err
		}
		state.Fingerprint = fingerprint
		if err := save(); err != nil {
			return err
		}
	}
	baseline := state.Fingerprint
	if baseline.PartSize != session.PartSize || len(baseline.Parts) != session.PartCount() {
		return errors.New("夸克上传分片基准无效")
	}
	if !state.QuarkHashed {
		if err := markUploadIntent(ctx, state, "quark-hash", save); err != nil {
			return err
		}
		result, err := u.providers.Quark.NegotiateUploadHash(ctx, session, baseline.MD5, baseline.SHA1)
		if err != nil {
			var rejected *quark.ServiceError
			if errors.As(err, &rejected) || errors.Is(err, quark.ErrLoginExpired) {
				state.Intent = ""
				return errors.Join(err, save())
			}
			return err
		}
		state.QuarkHashed, state.Intent = true, ""
		if result == quark.InstantCompleted {
			state.Intent = "quark-finish"
			if err := save(); err != nil {
				return err
			}
			return u.confirmQuarkObject(ctx, state, save)
		}
		if err := save(); err != nil {
			return err
		}
	}
	var remote map[int]quark.UploadPartReceipt
	if len(state.QuarkParts) != 0 {
		list, err := u.providers.Quark.ListUploadParts(ctx, session, auth)
		if err != nil {
			return err
		}
		remote = make(map[int]quark.UploadPartReceipt, len(list))
		for _, receipt := range list {
			remote[receipt.Number] = receipt
		}
	}
	confirmed := make(map[int]bool, len(state.QuarkParts))
	var done int64
	for _, local := range state.QuarkParts {
		index := local.Number - 1
		actual, exists := remote[local.Number]
		if index < 0 || index >= len(baseline.Parts) || confirmed[local.Number] || !exists ||
			local.UploadID != session.UploadID || local.Size != actual.Size ||
			!strings.EqualFold(strings.Trim(local.ETag, `"`), strings.Trim(actual.ETag, `"`)) ||
			!strings.EqualFold(strings.Trim(local.ETag, `"`), baseline.Parts[index].MD5) {
			return errors.New("夸克服务端分片与已保存回执不一致")
		}
		confirmed[local.Number] = true
		done += int64(local.Size)
	}
	var missing []int
	for index := range session.PartCount() {
		if !confirmed[index+1] {
			missing = append(missing, index)
		}
	}
	if len(missing) != 0 {
		if err := open(); err != nil {
			return err
		}
	}
	u.report(entry, "uploading", done)
	if err := sendUploadParts(ctx, missing, u.req.ParallelParts, func(ctx context.Context, index int) (quark.UploadPartReceipt, error) {
		return uploadPart(ctx, source, baseline, entry.Size, index, &u.upload,
			func(data []byte) (quark.UploadPartReceipt, error) {
				return u.providers.Quark.UploadPart(ctx, session, auth, index+1, data)
			})
	}, func(receipt quark.UploadPartReceipt) error {
		state.QuarkParts = append(state.QuarkParts, receipt)
		if err := save(); err != nil {
			return err
		}
		done += int64(receipt.Size)
		u.report(entry, "uploading", done)
		return source.verify()
	}); err != nil {
		return err
	}
	u.report(entry, "committing", done)
	if err := markUploadIntent(ctx, state, "quark-merge", save); err != nil {
		return err
	}
	if err := u.providers.Quark.CompleteUploadParts(ctx, session, auth, state.QuarkParts); err != nil {
		return err
	}
	// A durable merge receipt permits the first finish call after restart.
	state.Intent = "quark-merged"
	if err := save(); err != nil {
		return err
	}
	return u.finishQuark(ctx, state, save)
}

func (u *uploadRun) finishQuark(ctx context.Context, state *uploadItemState, save func() error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	state.Intent = "quark-finish"
	if err := save(); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		state.Intent = "quark-merged"
		return errors.Join(err, save())
	}
	if err := u.providers.Quark.FinishUpload(ctx, *state.Quark); err != nil {
		return err
	}
	return u.confirmQuarkObject(ctx, state, save)
}

func (u *uploadRun) confirmQuarkObject(ctx context.Context, state *uploadItemState, save func() error) error {
	remote, err := u.checkQuarkObject(ctx, *state.Quark)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrUploadUnconfirmed, err)
	}
	state.Remote, state.Intent = remote, ""
	state.Name = remote.Name
	return save()
}

func (u *uploadRun) checkQuarkObject(ctx context.Context, session quark.UploadSession) (uploadRemoteItem, error) {
	for attempt := range 4 {
		entries, err := u.providers.Quark.ListDirectory(ctx, session.ParentFID)
		if err != nil {
			return uploadRemoteItem{}, err
		}
		for _, item := range entries {
			if item.FID == session.FileID {
				if item.IsDirectory || item.Size != session.Size {
					return uploadRemoteItem{}, ErrUploadReadback
				}
				return uploadRemoteItem{Name: item.Name, FID: item.FID, Size: item.Size}, nil
			}
		}
		if attempt != 3 {
			if err := waitUpload(ctx, 200*time.Millisecond*(1<<attempt)); err != nil {
				return uploadRemoteItem{}, err
			}
		}
	}
	link, err := u.providers.Quark.Download(ctx, session.FileID)
	if err != nil {
		return uploadRemoteItem{}, err
	}
	if link.Size != nil && *link.Size != session.Size {
		return uploadRemoteItem{}, ErrUploadReadback
	}
	return uploadRemoteItem{Name: session.Name, FID: session.FileID, Size: session.Size}, nil
}

func uploadPartLength(total int64, partSize, index int) int64 {
	return min(int64(partSize), total-int64(index)*int64(partSize))
}

func uploadPart[T any](ctx context.Context, source *uploadSource, baseline uploadFingerprint, total int64,
	index int, pacer *uploadPacer, send func([]byte) (T, error),
) (T, error) {
	var zero T
	length := int(uploadPartLength(total, baseline.PartSize, index))
	if err := pacer.wait(ctx, length); err != nil {
		return zero, err
	}
	data, err := readUploadBytes(ctx, source, baseline, index)
	if err != nil {
		return zero, err
	}
	for attempt := range 3 {
		receipt, err := send(data)
		if err == nil || attempt == 2 || ctx.Err() != nil || !retryUploadPart(err) {
			return receipt, err
		}
		if err := waitUpload(ctx, 300*time.Millisecond); err != nil {
			return zero, err
		}
		if err := pacer.wait(ctx, length); err != nil {
			return zero, err
		}
		if err := source.verify(); err != nil {
			return zero, err
		}
	}
	return zero, err
}

func retryUploadPart(err error) bool {
	var bHTTP baidu.HTTPError
	var qHTTP quark.HTTPError
	var oss *quark.StorageError
	var transport net.Error
	switch {
	case errors.As(err, &bHTTP):
		return uploadTemporaryHTTP(int(bHTTP))
	case errors.As(err, &qHTTP):
		return uploadTemporaryHTTP(int(qHTTP))
	case errors.As(err, &oss):
		return uploadTemporaryHTTP(oss.Status)
	case errors.As(err, &transport):
		return true
	}
	return false
}

func uploadTemporaryHTTP(status int) bool { return status == 429 || status >= 500 && status < 600 }

func (u *uploadRun) verify(ctx context.Context, entry uploadLocalItem, state uploadItemState) error {
	if state.Fingerprint.SHA256 == "" || state.Remote.Size != entry.Size {
		return ErrUploadReadback
	}
	var address *url.URL
	var headers http.Header
	if u.req.Target.Provider == "baidu" {
		remote := state.Remote
		list, err := u.providers.Baidu.ListDirectory(ctx, path.Dir(remote.Path))
		if err != nil {
			return err
		}
		if !slices.ContainsFunc(list, func(item baidu.Entry) bool {
			return item.FSID == remote.FSID && item.Path == remote.Path && !item.IsDirectory && item.Size == entry.Size
		}) {
			return ErrUploadUnconfirmed
		}
		link, err := u.providers.Baidu.DownloadLink(ctx, remote.Path, 0)
		if err != nil {
			return err
		}
		address, headers = link.URL, link.Headers
	} else {
		link, err := u.providers.Quark.Download(ctx, state.Remote.FID)
		if err != nil {
			return err
		}
		if link.Size != nil && *link.Size != entry.Size {
			return ErrUploadReadback
		}
		address, headers = link.URL, link.Headers
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address.String(), nil)
	if err != nil {
		return errors.New("上传回读地址格式无效")
	}
	req.Header = headers.Clone()
	if req.Header == nil {
		req.Header = make(http.Header)
	}
	req.Header.Set("Accept-Encoding", "identity")
	req.Header.Del("Range")
	response, err := u.client.Do(req)
	if err != nil {
		var requestErr *url.Error
		if errors.As(err, &requestErr) {
			err = requestErr.Err
		}
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("上传回读请求失败，HTTP %d", response.StatusCode)
	}
	if response.ContentLength >= 0 && response.ContentLength != entry.Size {
		return ErrUploadReadback
	}
	digest, err := hashUploadReadback(ctx, response.Body, entry.Size, &u.readback,
		func(done int64) { u.report(entry, "verifying", done) })
	if err != nil {
		return err
	}
	if digest != state.Fingerprint.SHA256 {
		return ErrUploadReadback
	}
	return nil
}

func uploadReadbackClient(base *http.Client) *http.Client {
	if base == nil {
		base = http.DefaultClient
	}
	client := *base
	client.Jar = nil
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return errors.New("上传回读地址重定向次数过多")
		}
		if base.CheckRedirect != nil {
			if err := base.CheckRedirect(req, via); err != nil {
				return err
			}
		}
		original := via[0]
		if !strings.EqualFold(original.URL.Host, req.URL.Host) || original.URL.Scheme != req.URL.Scheme {
			req.Header.Del("Cookie")
			req.Header.Del("Authorization")
			req.Header.Del("Proxy-Authorization")
		}
		req.Header.Set("Accept-Encoding", "identity")
		return nil
	}
	return &client
}
