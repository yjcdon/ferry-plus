package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"path"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
	"github.com/yjcdon/ferry-drive/desktop/internal/quark"
	"github.com/yjcdon/ferry-drive/desktop/internal/store"
)

var ErrShareTransferUnconfirmed = errors.New("分享转存结果尚未确认，已保留转存目录。")

const shareOwnedPrefix = "FerryDrive-"

type ShareCleanup struct {
	Provider  Provider
	AccountID string
	Root      RemoteRef
	Parent    RemoteRef
	Name      string
}

// Cleanup recycles only the exact job-owned directory under its original parent.
func (c ShareCleanup) Cleanup(ctx context.Context, session AccountSession) error {
	found, err := c.owned(ctx, session)
	if err != nil || !found {
		return err
	}
	switch c.Provider {
	case Baidu:
		return session.Baidu.Delete(ctx, []string{c.Root.Path})
	case Quark:
		return session.Quark.Delete(ctx, []string{c.Root.ID})
	default:
		return ErrShareAccount
	}
}

func (c ShareCleanup) owned(ctx context.Context, session AccountSession) (bool, error) {
	if c.AccountID == "" || session.State != LoggedIn || session.ID != c.AccountID {
		return false, ErrShareAccount
	}
	if c.Root.Provider != c.Provider || c.Parent.Provider != c.Provider || c.Root == c.Parent ||
		c.Root.ID == "" || c.Root.ID == "0" || !strings.HasPrefix(c.Name, shareOwnedPrefix) || !shareName(c.Name) {
		return false, ErrShareTransferUnconfirmed
	}
	children, err := listRemote(ctx, session, c.Parent)
	if err != nil {
		return false, err
	}
	for _, entry := range children {
		if entry.Ref == c.Root {
			if !entry.IsDirectory || entry.Name != c.Name {
				return false, ErrShareTransferUnconfirmed
			}
			return true, nil
		}
		if entry.Name == c.Name {
			return false, ErrShareTransferUnconfirmed
		}
	}
	return false, nil
}

// DownloadTaskItem keeps the frozen remote identity and local relative path.
// An explicit digest is an original content expectation, separate from raw
// metadata returned for a transferred cloud object.
type DownloadTaskItem struct {
	Entry          RemoteEntry
	RelativePath   string
	ExpectedMD5    string
	ExpectedSHA256 string
}

type ShareDownload struct {
	Provider  Provider
	AccountID string
	Title     string
	Items     []DownloadTaskItem
	Cleanup   ShareCleanup
}

type shareRecords interface {
	Read(string, any) error
	Write(string, any) error
	Remove(string) error
	ReadCredential(string) ([]byte, error)
	WriteCredential(string, []byte) error
	RemoveCredential(string) error
}

type ShareTransfer struct {
	records  shareRecords
	accounts *Accounts
	mu       sync.Mutex
	active   map[string]bool
}

func NewShareTransfer(records *store.Store, accounts *Accounts) *ShareTransfer {
	return newShareTransfer(records, accounts)
}

func newShareTransfer(records shareRecords, accounts *Accounts) *ShareTransfer {
	return &ShareTransfer{records: records, accounts: accounts, active: make(map[string]bool)}
}

type shareExpected struct {
	Path string
	Size int64
	MD5  string
}

type shareBatch struct {
	Source      RemoteRef
	Relative    string
	Indices     []int
	Destination RemoteRef
	Submitted   bool
	TaskID      string
	Complete    bool
}

type shareTransferRecord struct {
	Provider   Provider
	AccountID  string
	URL        string
	HasCode    bool
	Title      string
	BaseFolder string
	Anchors    []shareAnchor
	Expected   []shareExpected
	Cleanup    ShareCleanup
	MakingRoot bool
	BaiduSent  bool
	Complete   bool
	Batches    []shareBatch
}

func shareJobKey(id string) string {
	return fmt.Sprintf("share-transfer-%x", sha256.Sum256([]byte(id)))
}

func (t *ShareTransfer) claim(id string) (string, func(), error) {
	if id == "" {
		return "", nil, errors.New("缺少分享转存任务标识。")
	}
	key := shareJobKey(id)
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.active[key] {
		return "", nil, errors.New("分享转存正在进行。")
	}
	t.active[key] = true
	return key, func() {
		t.mu.Lock()
		delete(t.active, key)
		t.mu.Unlock()
	}, nil
}

// Stage durably records a selection before its task is queued. Short-lived
// provider tokens remain in the share browser and never enter the task record.
func (t *ShareTransfer) Stage(id string, selection ShareSelection, baseFolder string) error {
	key, release, err := t.claim(id)
	if err != nil {
		return err
	}
	defer release()
	_, err = t.stageRecord(key, selection, baseFolder)
	return err
}

// DiscardStage rolls back a staged job that could not be added to the queue.
func (t *ShareTransfer) DiscardStage(id string) error {
	key, release, err := t.claim(id)
	if err != nil {
		return err
	}
	defer release()
	var record shareTransferRecord
	if err := t.records.Read(key, &record); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if record.MakingRoot || record.Cleanup.Root.ID != "" || record.BaiduSent ||
		slices.ContainsFunc(record.Batches, func(batch shareBatch) bool { return batch.Submitted }) {
		return ErrShareTransferUnconfirmed
	}
	if err := t.records.Remove(key); err != nil {
		return err
	}
	return t.records.RemoveCredential(key)
}

// Prepare records the selection and prepares a download in one worker call.
func (t *ShareTransfer) Prepare(ctx context.Context, id string, selection ShareSelection, baseFolder string) (ShareDownload, error) {
	key, release, err := t.claim(id)
	if err != nil {
		return ShareDownload{}, err
	}
	defer release()
	record, err := t.stageRecord(key, selection, baseFolder)
	if err != nil {
		return ShareDownload{}, err
	}
	return t.run(ctx, key, &record, &selection.access)
}

func (t *ShareTransfer) stageRecord(key string, selection ShareSelection, baseFolder string) (shareTransferRecord, error) {
	if len(selection.anchors) == 0 {
		return shareTransferRecord{}, ErrShareSelection
	}
	a := selection.access
	if !sameDirectorySession(a.session, t.accounts.Session(a.link.Provider)) {
		return shareTransferRecord{}, ErrShareAccount
	}
	if baseFolder == "" {
		baseFolder = "/Ferry"
		if a.link.Provider == Quark {
			baseFolder = "/Ferry Plus"
		}
	}
	if !validShareFolder(baseFolder) {
		return shareTransferRecord{}, errors.New("转存目录路径无效。")
	}
	var record shareTransferRecord
	if err := t.records.Read(key, &record); err == nil {
		if record.Provider != a.link.Provider || record.AccountID != a.session.ID ||
			record.URL != a.link.URL || record.BaseFolder != baseFolder || !sameShareAnchors(record.Anchors, selection.anchors) {
			return shareTransferRecord{}, errors.New("分享转存任务与原有记录不一致。")
		}
		return record, nil
	} else if !errors.Is(err, fs.ErrNotExist) {
		return shareTransferRecord{}, err
	}
	record = shareTransferRecord{Provider: a.link.Provider, AccountID: a.session.ID, URL: a.link.URL, HasCode: a.link.Passcode != "",
		Title: a.title, BaseFolder: baseFolder, Anchors: selection.anchors}
	if record.HasCode {
		if err := t.records.WriteCredential(key, []byte(a.link.Passcode)); err != nil {
			return shareTransferRecord{}, err
		}
	}
	if err := t.records.Write(key, record); err != nil {
		if record.HasCode {
			err = errors.Join(err, t.records.RemoveCredential(key))
		}
		return shareTransferRecord{}, err
	}
	return record, nil
}

// Resume reconciles exact saved task IDs and requests new tokens only for work
// that has not been submitted. It never submits an unresolved batch twice.
func (t *ShareTransfer) Resume(ctx context.Context, id string) (ShareDownload, error) {
	key, release, err := t.claim(id)
	if err != nil {
		return ShareDownload{}, err
	}
	defer release()
	var record shareTransferRecord
	if err := t.records.Read(key, &record); err != nil {
		return ShareDownload{}, err
	}
	return t.run(ctx, key, &record, nil)
}

// Cleanup retries removal after the caller has confirmed that staging may be recycled.
func (t *ShareTransfer) Cleanup(ctx context.Context, id string) error {
	key, release, err := t.claim(id)
	if err != nil {
		return err
	}
	defer release()
	var record shareTransferRecord
	if err := t.records.Read(key, &record); err != nil {
		return err
	}
	return record.Cleanup.Cleanup(ctx, t.accounts.Session(record.Provider))
}

func (t *ShareTransfer) run(ctx context.Context, key string, record *shareTransferRecord, access *shareAccess) (ShareDownload, error) {
	session := t.accounts.Session(record.Provider)
	if session.State != LoggedIn || session.ID != record.AccountID {
		return ShareDownload{}, ErrShareAccount
	}
	save := func() error { return t.records.Write(key, *record) }
	sameSession := func() bool { return sameDirectorySession(session, t.accounts.Session(record.Provider)) }
	requireAccess := func() (shareAccess, error) {
		if access != nil && sameDirectorySession(access.session, session) {
			return *access, nil
		}
		link := ShareLink{Provider: record.Provider, URL: record.URL}
		if record.HasCode {
			secret, err := t.records.ReadCredential(key)
			if err != nil {
				return shareAccess{}, err
			}
			link.Passcode = string(secret)
		}
		a, err := openShareAccess(ctx, session, link)
		if err == nil {
			access = &a
		}
		return a, err
	}
	if record.Expected == nil {
		a, err := requireAccess()
		if err != nil {
			return ShareDownload{}, err
		}
		selected, err := resolveShareAnchors(ctx, a, record.Anchors)
		if err != nil {
			return ShareDownload{}, err
		}
		record.Expected, err = shareManifest(ctx, a, selected)
		if err != nil {
			return ShareDownload{}, err
		}
		if record.Provider == Quark {
			record.Batches = planShareBatches(record.Anchors)
		}
		if err := save(); err != nil {
			return ShareDownload{}, err
		}
	}
	if record.Cleanup.Root.ID == "" {
		if record.MakingRoot {
			return ShareDownload{}, ErrShareTransferUnconfirmed
		}
		parent, err := ensureShareBase(ctx, session, record.Provider, record.BaseFolder)
		if err != nil {
			return ShareDownload{}, err
		}
		name := shareOwnedPrefix + strings.TrimPrefix(key, "share-transfer-")[:12]
		children, err := listRemote(ctx, session, parent)
		if err != nil {
			return ShareDownload{}, err
		}
		for _, child := range children {
			if child.Name == name {
				return ShareDownload{}, ErrShareTransferUnconfirmed
			}
		}
		record.Cleanup = ShareCleanup{Provider: record.Provider, AccountID: record.AccountID, Parent: parent, Name: name}
		record.MakingRoot = true
		if err := save(); err != nil {
			return ShareDownload{}, err
		}
		if !sameSession() || ctx.Err() != nil {
			record.MakingRoot = false
			if err := save(); err != nil {
				return ShareDownload{}, err
			}
			if ctx.Err() != nil {
				return ShareDownload{}, ctx.Err()
			}
			return ShareDownload{}, ErrShareAccount
		}
		root, err := createShareRoot(ctx, session, parent, name)
		if err != nil {
			return ShareDownload{}, fmt.Errorf("%w %w", ErrShareTransferUnconfirmed, err)
		}
		if root.ID == "" || root.ID == "0" || root == parent ||
			slices.ContainsFunc(children, func(child RemoteEntry) bool { return child.Ref == root }) {
			return ShareDownload{}, ErrShareTransferUnconfirmed
		}
		record.Cleanup.Root, record.MakingRoot = root, false
		if err := save(); err != nil {
			return ShareDownload{}, err
		}
	}
	found, err := record.Cleanup.owned(ctx, session)
	if err != nil {
		return ShareDownload{}, err
	}
	if !found {
		return ShareDownload{}, ErrShareTransferUnconfirmed
	}
	if !record.Complete {
		switch record.Provider {
		case Baidu:
			if !record.BaiduSent {
				a, err := requireAccess()
				if err != nil {
					return ShareDownload{}, err
				}
				nodes, err := resolveShareAnchors(ctx, a, record.Anchors)
				if err != nil {
					return ShareDownload{}, err
				}
				entries := make([]baidu.ShareEntry, 0, len(nodes))
				for _, node := range nodes {
					entries = append(entries, node.baidu)
				}
				if !sameSession() {
					return ShareDownload{}, ErrShareAccount
				}
				record.BaiduSent = true
				if err := save(); err != nil {
					return ShareDownload{}, err
				}
				if err := ctx.Err(); err != nil {
					record.BaiduSent = false
					return ShareDownload{}, errors.Join(err, save())
				}
				if err := session.Baidu.Transfer(ctx, a.baidu, entries, record.Cleanup.Root.Path); err != nil {
					return ShareDownload{}, fmt.Errorf("%w %w", ErrShareTransferUnconfirmed, err)
				}
			}
		case Quark:
			for i := range record.Batches {
				batch := &record.Batches[i]
				if batch.Complete {
					continue
				}
				if batch.TaskID == "" && batch.Submitted {
					return ShareDownload{}, ErrShareTransferUnconfirmed
				}
				if !batch.Submitted {
					a, err := requireAccess()
					if err != nil {
						return ShareDownload{}, err
					}
					anchors := make([]shareAnchor, 0, len(batch.Indices))
					for _, index := range batch.Indices {
						if index < 0 || index >= len(record.Anchors) {
							return ShareDownload{}, ErrShareTransferUnconfirmed
						}
						anchors = append(anchors, record.Anchors[index])
					}
					nodes, err := resolveShareAnchors(ctx, a, anchors)
					if err != nil {
						return ShareDownload{}, err
					}
					entries := make([]quark.Entry, 0, len(nodes))
					for _, node := range nodes {
						entries = append(entries, node.quark)
					}
					dest, err := ensureQuarkFolder(ctx, session, record.Cleanup.Root, batch.Relative)
					if err != nil {
						return ShareDownload{}, err
					}
					if !sameSession() {
						return ShareDownload{}, ErrShareAccount
					}
					batch.Destination, batch.Submitted = dest, true
					if err := save(); err != nil {
						return ShareDownload{}, err
					}
					if err := ctx.Err(); err != nil {
						batch.Submitted = false
						return ShareDownload{}, errors.Join(err, save())
					}
					taskID, err := session.Quark.SubmitSave(ctx, a.quark, entries, dest.ID, batch.Source.ID)
					if err != nil {
						return ShareDownload{}, fmt.Errorf("%w %w", ErrShareTransferUnconfirmed, err)
					}
					batch.TaskID = taskID
					if err := save(); err != nil {
						return ShareDownload{}, err
					}
				}
				if _, err := session.Quark.WaitForTask(ctx, batch.TaskID, 60, time.Second); err != nil {
					return ShareDownload{}, err
				}
				batch.Complete = true
				if err := save(); err != nil {
					return ShareDownload{}, err
				}
			}
		}
	}
	items, err := collectShareDownload(ctx, session, record.Cleanup.Root, record.Expected)
	if err != nil {
		return ShareDownload{}, err
	}
	if !sameSession() {
		return ShareDownload{}, ErrShareAccount
	}
	if !record.Complete {
		record.Complete = true
		if err := save(); err != nil {
			return ShareDownload{}, err
		}
	}
	if record.HasCode {
		if err := t.records.RemoveCredential(key); err != nil {
			return ShareDownload{}, err
		}
	}
	return ShareDownload{Provider: record.Provider, AccountID: record.AccountID, Title: record.Title, Items: items, Cleanup: record.Cleanup}, nil
}

func sameShareAnchors(a, b []shareAnchor) bool {
	return slices.EqualFunc(a, b, func(x, y shareAnchor) bool { return x.Relative == y.Relative && x.Entry.Ref == y.Entry.Ref })
}

func validShareFolder(base string) bool {
	return strings.HasPrefix(base, "/") && path.Clean(base) == base &&
		(base == "/" || fs.ValidPath(strings.TrimPrefix(base, "/"))) && !strings.ContainsRune(base, 0)
}

func ensureShareBase(ctx context.Context, session AccountSession, provider Provider, base string) (RemoteRef, error) {
	if provider == Quark {
		return ensureQuarkFolder(ctx, session, Quark.RootRef(), strings.TrimPrefix(base, "/"))
	}
	if base == "/" {
		return Baidu.RootRef(), nil
	}
	if err := session.Baidu.CreateDirectory(ctx, base); err != nil {
		return RemoteRef{}, err
	}
	children, err := session.Baidu.ListDirectory(ctx, path.Dir(base))
	if err != nil {
		return RemoteRef{}, err
	}
	for _, child := range children {
		if child.Path == base && child.IsDirectory {
			return fromBaidu(child).Ref, nil
		}
	}
	return RemoteRef{}, ErrShareTransferUnconfirmed
}

func ensureQuarkFolder(ctx context.Context, session AccountSession, current RemoteRef, relative string) (RemoteRef, error) {
	if relative == "" || relative == "." {
		return current, nil
	}
	if !fs.ValidPath(relative) || strings.ContainsRune(relative, 0) {
		return RemoteRef{}, ErrShareSelection
	}
	for component := range strings.SplitSeq(relative, "/") {
		children, err := listRemote(ctx, session, current)
		if err != nil {
			return RemoteRef{}, err
		}
		found := false
		for _, child := range children {
			if child.Name == component {
				if !child.IsDirectory {
					return RemoteRef{}, ErrShareTransferUnconfirmed
				}
				current, found = child.Ref, true
				break
			}
		}
		if !found {
			fid, err := session.Quark.CreateDirectory(ctx, component, current.ID)
			if err != nil {
				return RemoteRef{}, err
			}
			current = RemoteRef{Provider: Quark, ID: fid}
		}
	}
	return current, nil
}

func createShareRoot(ctx context.Context, session AccountSession, parent RemoteRef, name string) (RemoteRef, error) {
	if parent.Provider == Baidu {
		entry, err := session.Baidu.CreateOwnedDirectory(ctx, path.Join(parent.Path, name))
		if err != nil {
			return RemoteRef{}, err
		}
		return fromBaidu(entry).Ref, nil
	}
	fid, err := session.Quark.CreateDirectory(ctx, name, parent.ID)
	return RemoteRef{Provider: Quark, ID: fid}, err
}

func planShareBatches(anchors []shareAnchor) []shareBatch {
	indexBySource := make(map[RemoteRef]int)
	var batches []shareBatch
	for index, anchor := range anchors {
		source := Quark.RootRef()
		if len(anchor.Parents) != 0 {
			source = anchor.Parents[len(anchor.Parents)-1].Ref
		}
		batch, exists := indexBySource[source]
		if !exists {
			batch = len(batches)
			indexBySource[source] = batch
			batches = append(batches, shareBatch{Source: source, Relative: path.Dir(anchor.Relative)})
		}
		batches[batch].Indices = append(batches[batch].Indices, index)
	}
	return batches
}

func resolveShareAnchors(ctx context.Context, access shareAccess, anchors []shareAnchor) ([]shareNode, error) {
	cache := make(map[RemoteRef][]shareNode)
	find := func(parent *shareNode, expected RemoteEntry) (shareNode, error) {
		key := access.link.Provider.RootRef()
		if parent != nil {
			key = parent.entry.Ref
		}
		children, ok := cache[key]
		if !ok {
			var err error
			children, err = access.list(ctx, parent)
			if err != nil {
				return shareNode{}, err
			}
			cache[key] = children
		}
		for _, child := range children {
			if child.entry.Ref == expected.Ref && child.entry.Name == expected.Name && child.entry.IsDirectory == expected.IsDirectory &&
				(child.entry.IsDirectory || child.entry.Size == expected.Size) {
				return child, nil
			}
		}
		return shareNode{}, ErrShareSelection
	}
	result := make([]shareNode, 0, len(anchors))
	for _, anchor := range anchors {
		var parent *shareNode
		for _, expected := range anchor.Parents {
			node, err := find(parent, expected)
			if err != nil {
				return nil, err
			}
			parent = &node
		}
		node, err := find(parent, anchor.Entry)
		if err != nil || node.relative != anchor.Relative {
			return nil, errors.Join(ErrShareSelection, err)
		}
		result = append(result, node)
	}
	return result, nil
}

func shareManifest(ctx context.Context, access shareAccess, nodes []shareNode) ([]shareExpected, error) {
	stack := slices.Clone(nodes)
	seen := make(map[RemoteRef]bool)
	names := make(map[string]bool)
	var result []shareExpected
	for len(stack) > 0 {
		node := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if seen[node.entry.Ref] || names[node.relative] {
			return nil, ErrShareSelection
		}
		seen[node.entry.Ref], names[node.relative] = true, true
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if node.entry.IsDirectory {
			children, err := access.list(ctx, &node)
			if err != nil {
				return nil, err
			}
			stack = append(stack, children...)
		} else {
			result = append(result, shareExpected{Path: node.relative, Size: node.entry.Size, MD5: shareMD5(node.entry.MD5)})
		}
	}
	if len(result) == 0 {
		return nil, errors.New("所选分享目录中没有可下载的文件。")
	}
	slices.SortFunc(result, func(a, b shareExpected) int { return strings.Compare(a.Path, b.Path) })
	return result, nil
}

func collectShareDownload(ctx context.Context, session AccountSession, root RemoteRef, manifest []shareExpected) ([]DownloadTaskItem, error) {
	type work struct {
		ref RemoteRef
		rel string
	}
	stack := []work{{ref: root}}
	seen := map[RemoteRef]bool{root: true}
	expected := make(map[string]shareExpected, len(manifest))
	for _, item := range manifest {
		expected[item.Path] = item
	}
	result := make([]DownloadTaskItem, 0, len(manifest))
	for len(stack) > 0 {
		parent := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		children, err := listRemote(ctx, session, parent.ref)
		if err != nil {
			return nil, err
		}
		for _, item := range children {
			if seen[item.Ref] {
				return nil, ErrShareTransferUnconfirmed
			}
			seen[item.Ref] = true
			relative := path.Join(parent.rel, item.Name)
			if item.IsDirectory {
				stack = append(stack, work{item.Ref, relative})
				continue
			}
			want, ok := expected[relative]
			if !ok || want.Size != item.Size {
				return nil, fmt.Errorf("%w 文件：%s", ErrShareTransferUnconfirmed, relative)
			}
			item.MD5 = want.MD5
			download := DownloadTaskItem{Entry: item, RelativePath: relative}
			if root.Provider == Quark {
				// Quark supplies the original content MD5; Baidu metadata may
				// contain an obfuscated digest and is not a content expectation.
				download.ExpectedMD5 = shareMD5(want.MD5)
			}
			result = append(result, download)
			delete(expected, relative)
		}
	}
	if len(expected) != 0 || len(result) == 0 {
		return nil, ErrShareTransferUnconfirmed
	}
	slices.SortFunc(result, func(a, b DownloadTaskItem) int { return strings.Compare(a.RelativePath, b.RelativePath) })
	return result, nil
}

func shareMD5(value string) string {
	data, err := hex.DecodeString(value)
	if err != nil || len(data) != 16 || !slices.ContainsFunc(data, func(b byte) bool { return b != 0 }) {
		return ""
	}
	return strings.ToLower(value)
}
