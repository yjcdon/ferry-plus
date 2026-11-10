package app

import (
	"context"
	"errors"
	"path"
	"slices"
	"strconv"
	"strings"
)

var (
	errUploadCloudMissing = errors.New("云端文件或目录已变化，请刷新网盘后重试。")
	errUploadCloudAccount = errors.New("请先登录任务所属的网盘账号，再打开云端目录。")
)

// UploadCloudLocation binds a resolved folder and optional file focus to the
// exact account session that was used to read it.
type UploadCloudLocation struct {
	provider Provider
	session  AccountSession
	trail    []RemoteEntry
	children []RemoteEntry
	focus    RemoteRef
}

func (l UploadCloudLocation) Provider() Provider { return l.provider }
func (l UploadCloudLocation) Focus() RemoteRef   { return l.focus }

// Apply adopts the verified folder contents and focuses its exact file.
func (l UploadCloudLocation) Apply(accounts *Accounts, directory *Directory) bool {
	if directory.provider != l.provider || !sameDirectorySession(l.session, accounts.Session(l.provider)) {
		return false
	}
	directory.SetSession(l.session)
	directory.trail = slices.Clone(l.trail)
	directory.setRoot()
	directory.query = ""
	directory.resetTree()
	children := slices.Clone(l.children)
	if children == nil {
		children = []RemoteEntry{}
	}
	directory.sortEntries(children)
	directory.branches[directory.root] = directoryBranch{children: children}
	for _, child := range children {
		directory.entries[child.Ref] = child
		directory.parents[child.Ref] = directory.root
	}
	if l.focus.ID != "" {
		directory.SetSelection([]RemoteRef{l.focus})
	}
	return true
}

// LocateUploadCloud follows confirmed folder and file identities from the
// original upload target. The account and task are checked again after reads.
func (t *Transfers) LocateUploadCloud(ctx context.Context, id, relative string) (UploadCloudLocation, error) {
	job, item, err := t.savedUploadLocation(id, relative)
	if err != nil {
		return UploadCloudLocation{}, err
	}
	if item.Remote.Provider != job.Provider || item.Remote.ID == "" || item.Remote == job.Provider.RootRef() {
		return UploadCloudLocation{}, errUploadCloudMissing
	}
	session := t.accounts.Session(job.Provider)
	if session.State != LoggedIn || session.ID != job.AccountID {
		return UploadCloudLocation{}, errUploadCloudAccount
	}

	base := uploadTargetRef(job)
	trail, err := uploadCloudTrail(ctx, session, base, job.UploadTrail)
	if err != nil {
		return UploadCloudLocation{}, err
	}
	parent := base
	var folders []RemoteRef
	for dir := path.Dir(relative); dir != "." && dir != "/"; dir = path.Dir(dir) {
		index := slices.IndexFunc(job.Items, func(candidate TransferItem) bool { return candidate.RelativePath == dir })
		if index < 0 || !job.Items[index].Directory || job.Items[index].Remote.Provider != job.Provider || job.Items[index].Remote.ID == "" {
			return UploadCloudLocation{}, errUploadCloudMissing
		}
		folders = append(folders, job.Items[index].Remote)
	}
	slices.Reverse(folders)
	if item.Directory {
		folders = append(folders, item.Remote)
	}
	for _, folder := range folders {
		entry, err := uploadCloudChild(ctx, session, parent, folder)
		if err != nil {
			return UploadCloudLocation{}, err
		}
		trail, parent = append(trail, entry), entry.Ref
	}
	children, err := listRemote(ctx, session, parent)
	if err != nil {
		return UploadCloudLocation{}, err
	}
	var focus RemoteRef
	if !item.Directory {
		if !slices.ContainsFunc(children, func(child RemoteEntry) bool { return !child.IsDirectory && child.Ref == item.Remote }) {
			return UploadCloudLocation{}, errUploadCloudMissing
		}
		focus = item.Remote
	}
	if err := ctx.Err(); err != nil {
		return UploadCloudLocation{}, err
	}
	if !sameDirectorySession(session, t.accounts.Session(job.Provider)) {
		return UploadCloudLocation{}, errUploadCloudAccount
	}
	latest, current, err := t.savedUploadLocation(id, relative)
	if err != nil || latest.AccountID != job.AccountID || latest.Upload.Target != job.Upload.Target ||
		current.Remote != item.Remote || current.Directory != item.Directory {
		return UploadCloudLocation{}, errUploadCloudMissing
	}
	return UploadCloudLocation{provider: job.Provider, session: session, trail: trail, children: children, focus: focus}, nil
}

func uploadTargetRef(job transferRecord) RemoteRef {
	if job.Provider == Baidu {
		return RemoteRef{Provider: Baidu, Path: job.Upload.Target.Path, ID: strconv.FormatInt(job.Upload.Target.FSID, 10)}
	}
	return RemoteRef{Provider: Quark, ID: job.Upload.Target.FID}
}

func uploadCloudTrail(ctx context.Context, session AccountSession, target RemoteRef, saved []RemoteEntry) ([]RemoteEntry, error) {
	parent := target.Provider.RootRef()
	if target == parent {
		return nil, nil
	}
	var trail []RemoteEntry
	if len(saved) != 0 {
		if saved[len(saved)-1].Ref != target {
			return nil, errUploadCloudMissing
		}
		for _, folder := range saved {
			entry, err := uploadCloudChild(ctx, session, parent, folder.Ref)
			if err != nil {
				if target.Provider == Quark && errors.Is(err, errUploadCloudMissing) {
					return detachedUploadTrail(target), nil
				}
				return nil, err
			}
			trail, parent = append(trail, entry), entry.Ref
		}
		return trail, nil
	}
	if target.Provider == Quark {
		// Older 5.0 records kept only the FID. The exact folder still opens
		// by FID; a name or ancestry that was never stored is not guessed.
		if target.ID == "" {
			return nil, errUploadCloudMissing
		}
		return detachedUploadTrail(target), nil
	}
	if !strings.HasPrefix(target.Path, "/") || path.Clean(target.Path) != target.Path {
		return nil, errUploadCloudMissing
	}
	for name := range strings.SplitSeq(strings.TrimPrefix(target.Path, "/"), "/") {
		children, err := listRemote(ctx, session, parent)
		if err != nil {
			return nil, err
		}
		exactPath := path.Join(parent.Path, name)
		index := slices.IndexFunc(children, func(child RemoteEntry) bool { return child.IsDirectory && child.Ref.Path == exactPath })
		if index < 0 {
			return nil, errUploadCloudMissing
		}
		trail, parent = append(trail, children[index]), children[index].Ref
	}
	if parent != target {
		return nil, errUploadCloudMissing
	}
	return trail, nil
}

func detachedUploadTrail(target RemoteRef) []RemoteEntry {
	return []RemoteEntry{{Ref: target, Name: "已定位目录", IsDirectory: true}}
}

func uploadCloudChild(ctx context.Context, session AccountSession, parent, ref RemoteRef) (RemoteEntry, error) {
	children, err := listRemote(ctx, session, parent)
	if err != nil {
		return RemoteEntry{}, err
	}
	for _, child := range children {
		if child.IsDirectory && child.Ref == ref {
			return child, nil
		}
	}
	return RemoteEntry{}, errUploadCloudMissing
}

func (t *Transfers) savedUploadLocation(id, relative string) (transferRecord, TransferItem, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	index := t.find(id)
	if index < 0 {
		return transferRecord{}, TransferItem{}, errTransferMissing
	}
	job := t.jobs[index]
	if job.Upload == nil {
		return transferRecord{}, TransferItem{}, errTransferMissing
	}
	for _, item := range job.Items {
		if item.RelativePath == relative {
			job.Items = slices.Clone(job.Items)
			return job, item, nil
		}
	}
	return transferRecord{}, TransferItem{}, errTransferMissing
}

type uploadSourceRevealer interface {
	RevealUploadSource(string, string) error
}

// RevealUploadSource uses the task's durable file reference, including any
// source rebinding and a still-valid system bookmark.
func (t *Transfers) RevealUploadSource(id, relative string) error {
	if _, _, err := t.savedUploadLocation(id, relative); err != nil {
		return err
	}
	revealer, ok := t.upload.(uploadSourceRevealer)
	if !ok {
		return errors.New("无法读取上传源文件位置。")
	}
	return revealer.RevealUploadSource(id, relative)
}
