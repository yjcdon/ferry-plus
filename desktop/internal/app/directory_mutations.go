package app

import (
	"context"
	"errors"
	"fmt"
	"path"
	"slices"
	"strings"
	"time"
	"unicode"

	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
	"golang.org/x/text/unicode/norm"
)

var (
	ErrDirectorySessionChanged    = errors.New("请重新选择账号和项目。")
	ErrDirectoryEntryChanged      = errors.New("所选对象已变化，请刷新目录。")
	ErrDirectoryNameExists        = errors.New("此位置已有同名文件或文件夹，请换一个名称。")
	ErrDirectoryRenameUnconfirmed = errors.New("请刷新目录，确认文件名称。")
)

type DirectoryTarget struct {
	Ref       RemoteRef
	Trail     []RemoteEntry
	AccountID string
	session   AccountSession
}

func (t DirectoryTarget) Session(accounts *Accounts) (AccountSession, error) {
	current := accounts.Session(t.Ref.Provider)
	if current.State != LoggedIn || !sameDirectorySession(t.session, current) {
		return AccountSession{}, ErrDirectorySessionChanged
	}
	return current, nil
}

type DirectoryItem struct {
	Entry       RemoteEntry
	Parent      RemoteRef
	wasSelected bool
}

type DirectorySelection struct {
	Target DirectoryTarget
	Items  []DirectoryItem
}

type DirectoryFailure struct {
	Entry RemoteEntry
	Err   error
}

type DirectoryTrashResult struct {
	Removed  []DirectoryItem
	Failures []DirectoryFailure
}

// Target freezes a current directory or an existing descendant directory.
func (d *Directory) Target(ref RemoteRef) (DirectoryTarget, bool) {
	if d.session.State != LoggedIn || !d.Loaded(d.root) || d.Loading(d.root) || d.LoadError(d.root) != nil {
		return DirectoryTarget{}, false
	}
	trail := d.Trail()
	if ref != d.root {
		entry, ok := d.entries[ref]
		if !ok || !entry.IsDirectory {
			return DirectoryTarget{}, false
		}
		trail = append(trail, d.pathTo(ref)...)
	}
	return DirectoryTarget{Ref: ref, Trail: trail, AccountID: d.session.ID, session: d.session}, true
}

// FreezeSelection uses each row's actual parent and removes redundant descendants.
func (d *Directory) FreezeSelection(refs []RemoteRef) (DirectorySelection, bool) {
	target, ok := d.Target(d.root)
	if !ok || len(refs) == 0 {
		return DirectorySelection{}, false
	}
	chosen := make(map[RemoteRef]bool, len(refs))
	for _, ref := range refs {
		if _, ok := d.entries[ref]; !ok {
			return DirectorySelection{}, false
		}
		chosen[ref] = true
	}
	selection := DirectorySelection{Target: target}
	added := make(map[RemoteRef]bool, len(refs))
	for _, ref := range refs {
		if added[ref] {
			continue
		}
		parent := d.parents[ref]
		nested := false
		for ancestor := parent; ancestor != d.root; ancestor = d.parents[ancestor] {
			if chosen[ancestor] {
				nested = true
				break
			}
		}
		if nested {
			continue
		}
		added[ref] = true
		selection.Items = append(selection.Items, DirectoryItem{d.entries[ref], parent, d.selected[ref]})
	}
	return selection, len(selection.Items) > 0
}

// DefaultFolderName selects the first unused visible default name.
func (d *Directory) DefaultFolderName() string {
	names := make(map[string]bool)
	for _, entry := range d.branches[d.root].children {
		names[entry.Name] = true
	}
	const base = "未命名文件夹"
	name := base
	for suffix := 2; names[name]; suffix++ {
		name = fmt.Sprintf("%s %d", base, suffix)
	}
	return name
}

// ValidateRemoteName applies the shared rename field rules from both providers.
func ValidateRemoteName(name string) error {
	switch {
	case strings.TrimSpace(name) == "":
		return errors.New("请输入名称")
	case name == "." || name == "..":
		return errors.New("请换一个名称")
	case strings.ContainsAny(name, "\\/:*?\"'<>|") || strings.ContainsFunc(name, unicode.IsControl):
		return errors.New("包含非法字符")
	}
	return nil
}

// Create submits a single directory request against the frozen account and parent.
func (t DirectoryTarget) Create(ctx context.Context, accounts *Accounts, name string) (RemoteEntry, error) {
	if err := ValidateRemoteName(name); err != nil {
		return RemoteEntry{}, err
	}
	session, err := t.Session(accounts)
	if err != nil {
		return RemoteEntry{}, err
	}
	var created RemoteEntry
	if t.Ref.Provider == Baidu {
		if t.Ref != Baidu.RootRef() {
			parent := RemoteRef{Provider: Baidu, Path: path.Dir(t.Ref.Path)}
			children, err := listRemote(ctx, session, parent)
			if err != nil {
				return RemoteEntry{}, err
			}
			if !slices.ContainsFunc(children, func(entry RemoteEntry) bool {
				return entry.IsDirectory && entry.Ref == t.Ref
			}) {
				return RemoteEntry{}, ErrDirectoryEntryChanged
			}
			if session, err = t.Session(accounts); err != nil {
				return RemoteEntry{}, err
			}
		}
		entry, err := session.Baidu.CreateOwnedDirectory(ctx, path.Join(t.Ref.Path, name))
		if err != nil {
			return RemoteEntry{}, err
		}
		created = fromBaidu(entry)
	} else {
		fid, err := session.Quark.CreateDirectory(ctx, name, t.Ref.ID)
		if err != nil {
			return RemoteEntry{}, err
		}
		created = RemoteEntry{Ref: RemoteRef{Provider: Quark, ID: fid}, Name: name, IsDirectory: true}
	}
	if _, err := t.Session(accounts); err != nil {
		return RemoteEntry{}, err
	}
	return created, nil
}

// Rename verifies the original identity and any name collision before writing,
// then confirms that the same object was renamed without replaying the request.
func (s DirectorySelection) Rename(ctx context.Context, accounts *Accounts, name string) (RemoteEntry, error) {
	if err := ValidateRemoteName(name); err != nil {
		return RemoteEntry{}, err
	}
	if len(s.Items) != 1 {
		return RemoteEntry{}, ErrDirectoryEntryChanged
	}
	item := s.Items[0]
	if item.Entry.Name == name {
		if _, err := s.Target.Session(accounts); err != nil {
			return RemoteEntry{}, err
		}
		return item.Entry, nil
	}
	session, siblings, err := s.mutationSelection(ctx, accounts, item)
	if err != nil {
		return RemoteEntry{}, err
	}
	for _, child := range siblings {
		if child.Ref != item.Entry.Ref && norm.NFC.String(child.Name) == norm.NFC.String(name) {
			return RemoteEntry{}, ErrDirectoryNameExists
		}
	}
	if s.Target.Ref.Provider == Baidu {
		err = session.Baidu.RenameWithoutReplacing(ctx, item.Entry.Ref.Path, name)
	} else {
		err = session.Quark.Rename(ctx, item.Entry.Ref.ID, name)
	}
	if errors.Is(err, baidu.ErrAlreadyExists) {
		return RemoteEntry{}, ErrDirectoryNameExists
	}
	if err != nil {
		return RemoteEntry{}, err
	}
	var updated RemoteEntry
	err = s.confirmMutation(ctx, accounts, item.Parent, func(entries []RemoteEntry) bool {
		for _, entry := range entries {
			if entry.Ref.ID == item.Entry.Ref.ID && entry.Name == name && entry.IsDirectory == item.Entry.IsDirectory &&
				(entry.IsDirectory || entry.Size == item.Entry.Size) {
				updated = entry
				return true
			}
		}
		return false
	})
	if err != nil {
		return RemoteEntry{}, err
	}
	if updated.Ref.ID == "" {
		return RemoteEntry{}, ErrDirectoryRenameUnconfirmed
	}
	return updated, nil
}

// Trash validates and moves each item individually so verified successes and
// item-specific failures can be shown independently.
func (s DirectorySelection) Trash(ctx context.Context, accounts *Accounts) DirectoryTrashResult {
	var result DirectoryTrashResult
	for _, item := range s.Items {
		err := s.trashItem(ctx, accounts, item)
		if err == nil {
			result.Removed = append(result.Removed, item)
		} else {
			result.Failures = append(result.Failures, DirectoryFailure{item.Entry, err})
		}
	}
	return result
}

func (s DirectorySelection) trashItem(ctx context.Context, accounts *Accounts, item DirectoryItem) error {
	session, _, err := s.mutationSelection(ctx, accounts, item)
	if err != nil {
		return err
	}
	if s.Target.Ref.Provider == Baidu {
		err = session.Baidu.Delete(ctx, []string{item.Entry.Ref.Path})
	} else {
		err = session.Quark.Delete(ctx, []string{item.Entry.Ref.ID})
	}
	if err != nil {
		return err
	}
	removed := false
	err = s.confirmMutation(ctx, accounts, item.Parent, func(entries []RemoteEntry) bool {
		removed = !slices.ContainsFunc(entries, func(entry RemoteEntry) bool { return entry.Ref == item.Entry.Ref })
		return removed
	})
	if err != nil {
		return err
	}
	if !removed {
		return errors.New("原目录仍返回所选对象，请刷新后核对。")
	}
	return nil
}

func (s DirectorySelection) mutationSelection(ctx context.Context, accounts *Accounts, item DirectoryItem) (AccountSession, []RemoteEntry, error) {
	session, err := s.Target.Session(accounts)
	if err != nil {
		return AccountSession{}, nil, err
	}
	if item.Entry.Ref.Provider != s.Target.Ref.Provider || item.Parent.Provider != s.Target.Ref.Provider ||
		item.Entry.Ref == item.Parent || item.Entry.Ref == s.Target.Ref.Provider.RootRef() {
		return AccountSession{}, nil, ErrDirectoryEntryChanged
	}
	children, err := listRemote(ctx, session, item.Parent)
	if err != nil {
		return AccountSession{}, nil, err
	}
	for _, entry := range children {
		if entry.Ref == item.Entry.Ref && entry.Name == item.Entry.Name && entry.IsDirectory == item.Entry.IsDirectory {
			session, err = s.Target.Session(accounts)
			return session, children, err
		}
	}
	return AccountSession{}, nil, ErrDirectoryEntryChanged
}

func (s DirectorySelection) confirmMutation(ctx context.Context, accounts *Accounts, parent RemoteRef, confirmed func([]RemoteEntry) bool) error {
	for attempt := range 4 {
		if attempt > 0 {
			timer := time.NewTimer(200 * time.Millisecond << (attempt - 1))
			select {
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			case <-timer.C:
			}
		}
		session, err := s.Target.Session(accounts)
		if err != nil {
			return err
		}
		children, err := listRemote(ctx, session, parent)
		if err != nil {
			return err
		}
		if confirmed(children) {
			_, err = s.Target.Session(accounts)
			return err
		}
	}
	return nil
}

func (d *Directory) sameTarget(target DirectoryTarget) bool {
	return target.Ref.Provider == d.provider && sameDirectorySession(d.session, target.session)
}

// ApplyCreated inserts a verified creation only into the original loaded parent.
func (d *Directory) ApplyCreated(target DirectoryTarget, entry RemoteEntry) bool {
	if !d.sameTarget(target) || !d.Loaded(target.Ref) || !validRemoteChild(target.Ref, entry) {
		return false
	}
	if _, exists := d.entries[entry.Ref]; exists {
		return false
	}
	d.cancelRequests()
	branch := d.branches[target.Ref]
	branch.children = append(branch.children, entry)
	d.sortEntries(branch.children)
	d.branches[target.Ref] = branch
	d.entries[entry.Ref], d.parents[entry.Ref] = entry, target.Ref
	if target.Ref == d.root {
		d.query = ""
		d.SetSelection([]RemoteRef{entry.Ref})
	}
	return true
}

// ApplyRenamed replaces the matching row with the verified current identity.
func (d *Directory) ApplyRenamed(selection DirectorySelection, entry RemoteEntry) bool {
	if !d.sameTarget(selection.Target) || len(selection.Items) != 1 {
		return false
	}
	item := selection.Items[0]
	old := item.Entry.Ref
	current, ok := d.entries[old]
	if !ok || current.Name != item.Entry.Name || !validRemoteChild(item.Parent, entry) ||
		entry.Ref.ID != old.ID || entry.IsDirectory != current.IsDirectory {
		return false
	}
	d.cancelRequests()
	selected := d.Selection()
	if old != entry.Ref {
		d.removeChildren(old)
		delete(d.expanded, old)
		delete(d.entries, old)
		delete(d.parents, old)
		selected = slices.DeleteFunc(selected, func(ref RemoteRef) bool { return ref == old })
	}
	branch := d.branches[item.Parent]
	for i, child := range branch.children {
		if child.Ref == old {
			branch.children[i] = entry
			break
		}
	}
	d.sortEntries(branch.children)
	d.entries[entry.Ref], d.parents[entry.Ref] = entry, item.Parent
	if item.wasSelected {
		selected = append(selected, entry.Ref)
	}
	d.SetSelection(selected)
	return true
}

// ApplyTrash removes only confirmed items from the view for the same session.
func (d *Directory) ApplyTrash(selection DirectorySelection, result DirectoryTrashResult) bool {
	if !d.sameTarget(selection.Target) || len(result.Removed) == 0 {
		return false
	}
	d.cancelRequests()
	selected := d.Selection()
	for _, item := range result.Removed {
		ref := item.Entry.Ref
		if _, ok := d.entries[ref]; !ok || d.parents[ref] != item.Parent {
			continue
		}
		d.removeChildren(ref)
		delete(d.expanded, ref)
		delete(d.entries, ref)
		delete(d.parents, ref)
		branch := d.branches[item.Parent]
		branch.children = slices.DeleteFunc(branch.children, func(entry RemoteEntry) bool { return entry.Ref == ref })
		d.branches[item.Parent] = branch
	}
	d.SetSelection(selected)
	return true
}
