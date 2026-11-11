package app

import (
	"context"
	"errors"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
	"github.com/yjcdon/ferry-drive/desktop/internal/quark"
	"golang.org/x/text/collate"
	"golang.org/x/text/language"
	"golang.org/x/text/unicode/norm"
)

// RemoteRef is an exact provider identity. Baidu needs both its path and
// fsID; Quark identifies objects with FIDs and has no path parameter.
type RemoteRef struct {
	Provider Provider `json:"provider"`
	ID       string   `json:"id"`
	Path     string   `json:"path,omitempty"`
}

func (p Provider) RootRef() RemoteRef {
	if p == Baidu {
		return RemoteRef{Provider: p, ID: "0", Path: "/"}
	}
	return RemoteRef{Provider: p, ID: quark.RootFID}
}

type RemoteEntry struct {
	Ref         RemoteRef  `json:"ref"`
	Name        string     `json:"name"`
	IsDirectory bool       `json:"isDirectory"`
	Size        int64      `json:"size"`
	ModifiedAt  *time.Time `json:"modifiedAt,omitempty"`
	MD5         string     `json:"md5,omitempty"`
}

type DirectorySort int

const (
	SortName DirectorySort = iota
	SortModified
	SortSize
)

// DirectoryLocation is restored only when its account matches the current session.
type DirectoryLocation struct {
	AccountID string        `json:"accountID"`
	Trail     []RemoteEntry `json:"trail"`
}

type directoryBranch struct {
	children []RemoteEntry
	err      error
}

// Directory owns one provider's visible tree. UI callers change it on the
// main thread; a frozen DirectoryRequest can fetch on a worker.
type Directory struct {
	provider   Provider
	session    AccountSession
	trail      []RemoteEntry
	restored   *DirectoryLocation
	root       RemoteRef
	generation uint64
	branches   map[RemoteRef]directoryBranch
	entries    map[RemoteRef]RemoteEntry
	parents    map[RemoteRef]RemoteRef
	expanded   map[RemoteRef]bool
	selected   map[RemoteRef]bool
	requests   map[RemoteRef]*DirectoryRequest
	query      string
	sort       DirectorySort
	descending bool
	names      *collate.Collator
}

func NewDirectory(provider Provider) *Directory {
	d := &Directory{provider: provider, root: provider.RootRef(), names: collate.New(language.Und, collate.Numeric, collate.IgnoreCase)}
	d.resetTree()
	return d
}

func (d *Directory) Provider() Provider   { return d.provider }
func (d *Directory) Root() RemoteRef      { return d.root }
func (d *Directory) Trail() []RemoteEntry { return slices.Clone(d.trail) }
func (d *Directory) CanGoUp() bool        { return len(d.trail) > 0 }

func (d *Directory) Location() DirectoryLocation {
	return DirectoryLocation{AccountID: d.session.ID, Trail: d.Trail()}
}

func (d *Directory) RestoreLocation(location DirectoryLocation) {
	if location.AccountID == "" {
		return
	}
	parent := d.provider.RootRef()
	for _, entry := range location.Trail {
		if !entry.IsDirectory || !validRemoteChild(parent, entry) {
			return
		}
		parent = entry.Ref
	}
	d.restored = &DirectoryLocation{AccountID: location.AccountID, Trail: slices.Clone(location.Trail)}
}

// SetSession cancels stale requests when the exact client changes. A
// replacement client for the same account keeps the current path.
func (d *Directory) SetSession(session AccountSession) bool {
	previous := d.session
	d.session = session
	if sameDirectorySession(previous, session) {
		return false
	}
	if previous.ID != session.ID {
		d.trail = nil
		d.query = ""
	}
	if session.State == LoggedIn && d.restored != nil {
		if session.ID == d.restored.AccountID && previous.State != LoggedIn {
			d.trail = d.restored.Trail
		}
		d.restored = nil
	}
	d.setRoot()
	d.resetTree()
	return true
}

func sameDirectorySession(a, b AccountSession) bool {
	return a.State == b.State && a.ID == b.ID && a.Baidu == b.Baidu && a.Quark == b.Quark
}

func (d *Directory) setRoot() {
	d.root = d.provider.RootRef()
	if len(d.trail) > 0 {
		d.root = d.trail[len(d.trail)-1].Ref
	}
}

func (d *Directory) resetTree() {
	d.cancelRequests()
	d.branches = make(map[RemoteRef]directoryBranch)
	d.entries = make(map[RemoteRef]RemoteEntry)
	d.parents = make(map[RemoteRef]RemoteRef)
	d.expanded = make(map[RemoteRef]bool)
	d.selected = make(map[RemoteRef]bool)
}

func (d *Directory) cancelRequests() {
	for _, request := range d.requests {
		request.cancel()
	}
	d.requests = make(map[RemoteRef]*DirectoryRequest)
	d.generation++
}

// Close cancels directory reads when the window or app closes.
func (d *Directory) Close() { d.cancelRequests() }

func (d *Directory) Navigate(index int) bool {
	if index < -1 || index >= len(d.trail) || index == len(d.trail)-1 {
		return false
	}
	d.trail = slices.Clone(d.trail[:index+1])
	d.setRoot()
	d.query = ""
	d.resetTree()
	return true
}

func (d *Directory) Up() bool { return d.Navigate(len(d.trail) - 2) }

func (d *Directory) Enter(ref RemoteRef) bool {
	if entry, ok := d.entries[ref]; !ok || !entry.IsDirectory {
		return false
	}
	path := d.pathTo(ref)
	if len(path) == 0 {
		return false
	}
	d.trail = append(d.trail, path...)
	d.setRoot()
	d.query = ""
	d.resetTree()
	return true
}

func (d *Directory) pathTo(ref RemoteRef) []RemoteEntry {
	var path []RemoteEntry
	for ref != d.root {
		entry, ok := d.entries[ref]
		if !ok {
			return nil
		}
		path = append(path, entry)
		ref = d.parents[ref]
	}
	slices.Reverse(path)
	return path
}

func (d *Directory) Entry(ref RemoteRef) (RemoteEntry, bool) {
	entry, ok := d.entries[ref]
	return entry, ok
}

func (d *Directory) Loading(ref RemoteRef) bool { return d.requests[ref] != nil }
func (d *Directory) Loaded(ref RemoteRef) bool {
	branch, ok := d.branches[ref]
	return ok && branch.children != nil
}

func (d *Directory) LoadError(ref RemoteRef) error { return d.branches[ref].err }

func (d *Directory) Roots() []RemoteEntry {
	children := d.branches[d.root].children
	if d.query == "" {
		return children
	}
	matches := make([]RemoteEntry, 0, len(children))
	for _, entry := range children {
		if strings.Contains(strings.ToLower(entry.Name), d.query) {
			matches = append(matches, entry)
		}
	}
	return matches
}

func (d *Directory) Children(ref RemoteRef) []RemoteEntry {
	if d.query != "" {
		return nil
	}
	return d.branches[ref].children
}

func (d *Directory) IsExpanded(ref RemoteRef) bool { return d.expanded[ref] && d.query == "" }

func (d *Directory) SetQuery(query string) {
	query = strings.ToLower(strings.TrimSpace(query))
	if query == d.query {
		return
	}
	d.query = query
	d.SetSelection(d.Selection())
}

func (d *Directory) SetSort(sort DirectorySort, descending bool) {
	if d.sort == sort && d.descending == descending {
		return
	}
	d.sort, d.descending = sort, descending
	for _, branch := range d.branches {
		d.sortEntries(branch.children)
	}
}

func (d *Directory) sortEntries(entries []RemoteEntry) {
	slices.SortStableFunc(entries, func(a, b RemoteEntry) int {
		if a.IsDirectory != b.IsDirectory {
			if a.IsDirectory {
				return -1
			}
			return 1
		}
		n := 0
		switch d.sort {
		case SortModified:
			if a.ModifiedAt == nil && b.ModifiedAt != nil {
				return 1
			}
			if a.ModifiedAt != nil && b.ModifiedAt == nil {
				return -1
			}
			if a.ModifiedAt != nil {
				n = a.ModifiedAt.Compare(*b.ModifiedAt)
			}
		case SortSize:
			if !a.IsDirectory {
				if a.Size < b.Size {
					n = -1
				} else if a.Size > b.Size {
					n = 1
				}
			}
		}
		if n == 0 {
			n = d.names.CompareString(a.Name, b.Name)
		}
		if n == 0 {
			n = strings.Compare(a.Ref.Path, b.Ref.Path)
			if n == 0 {
				n = strings.Compare(a.Ref.ID, b.Ref.ID)
			}
			return n
		}
		if d.descending {
			return -n
		}
		return n
	})
}

func (d *Directory) SetSelection(refs []RemoteRef) {
	requested := make(map[RemoteRef]bool, len(refs))
	for _, ref := range refs {
		requested[ref] = true
	}
	clear(d.selected)
	d.walkVisible(d.Roots(), func(entry RemoteEntry) bool {
		if !requested[entry.Ref] {
			return true
		}
		d.selected[entry.Ref] = true
		return false
	})
}

func (d *Directory) Selection() []RemoteRef {
	entries := d.SelectedEntries()
	refs := make([]RemoteRef, len(entries))
	for i, entry := range entries {
		refs[i] = entry.Ref
	}
	return refs
}

// SelectedThroughParent reports whether an explicitly selected folder includes ref.
func (d *Directory) SelectedThroughParent(ref RemoteRef) bool {
	for parent, ok := d.parents[ref]; ok; parent, ok = d.parents[parent] {
		if d.selected[parent] {
			return true
		}
	}
	return false
}

func (d *Directory) SelectedEntries() []RemoteEntry {
	var selected []RemoteEntry
	d.walkVisible(d.Roots(), func(entry RemoteEntry) bool {
		if !d.selected[entry.Ref] {
			return true
		}
		selected = append(selected, entry)
		return false
	})
	return selected
}

func (d *Directory) walkVisible(entries []RemoteEntry, visit func(RemoteEntry) bool) {
	for _, entry := range entries {
		if visit(entry) && d.IsExpanded(entry.Ref) {
			d.walkVisible(d.Children(entry.Ref), visit)
		}
	}
}

func (d *Directory) SelectAll() {
	if d.Loading(d.root) {
		return
	}
	clear(d.selected)
	for _, entry := range d.Roots() {
		d.selected[entry.Ref] = true
	}
}

// DirectoryRequest binds a read to an exact session, root and generation.
type DirectoryRequest struct {
	ref        RemoteRef
	session    AccountSession
	generation uint64
	expanded   map[RemoteRef]bool
	ctx        context.Context
	cancel     context.CancelFunc
}

type DirectoryResult struct {
	branches map[RemoteRef]directoryBranch
	err      error
}

// Refresh replaces root and previously expanded descendants together. The
// previous tree remains visible while the request is running or on failure.
func (d *Directory) Refresh() *DirectoryRequest {
	if d.session.State != LoggedIn {
		return nil
	}
	d.cancelRequests()
	expanded := make(map[RemoteRef]bool, len(d.expanded))
	for ref := range d.expanded {
		expanded[ref] = true
	}
	return d.request(d.root, expanded)
}

func (d *Directory) Expand(ref RemoteRef) *DirectoryRequest {
	entry, ok := d.entries[ref]
	if !ok || !entry.IsDirectory || d.query != "" || d.session.State != LoggedIn || d.Loading(d.root) {
		return nil
	}
	d.expanded[ref] = true
	if d.Loading(ref) || d.Loaded(ref) {
		return nil
	}
	return d.request(ref, nil)
}

func (d *Directory) Collapse(ref RemoteRef) {
	delete(d.expanded, ref)
	for child, request := range d.requests {
		if child == d.root {
			continue
		}
		for candidate := child; candidate != d.root; candidate = d.parents[candidate] {
			if candidate == ref {
				request.cancel()
				delete(d.requests, child)
				break
			}
			if _, ok := d.parents[candidate]; !ok {
				break
			}
		}
	}
	d.SetSelection(d.Selection())
}

func (d *Directory) request(ref RemoteRef, expanded map[RemoteRef]bool) *DirectoryRequest {
	ctx, cancel := context.WithCancel(context.Background())
	request := &DirectoryRequest{ref: ref, session: d.session, generation: d.generation, expanded: expanded, ctx: ctx, cancel: cancel}
	d.requests[ref] = request
	return request
}

func (r *DirectoryRequest) Ref() RemoteRef { return r.ref }

func (r *DirectoryRequest) Fetch(ctx context.Context) DirectoryResult {
	if err := r.ctx.Err(); err != nil {
		return DirectoryResult{err: err}
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stop := context.AfterFunc(r.ctx, cancel)
	defer stop()
	branches := make(map[RemoteRef]directoryBranch)
	seen := map[RemoteRef]bool{r.ref: true}
	var visit func(RemoteRef) error
	visit = func(ref RemoteRef) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		children, err := listRemote(ctx, r.session, ref)
		if err != nil {
			branches[ref] = directoryBranch{err: err}
			return err
		}
		for _, child := range children {
			if seen[child.Ref] {
				err = errors.New("网盘返回了重复的文件身份。")
				branches[ref] = directoryBranch{err: err}
				return err
			}
			seen[child.Ref] = true
		}
		branches[ref] = directoryBranch{children: children}
		for _, child := range children {
			if child.IsDirectory && r.expanded[child.Ref] {
				if err := visit(child.Ref); errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) ||
					isLoginExpired(ref.Provider, err) {
					return err
				}
			}
		}
		return nil
	}
	err := visit(r.ref)
	return DirectoryResult{branches: branches, err: err}
}

// ReportExpiredSession lets a directory response retire its original login
// without allowing a stale response to expire a replacement account.
func (r *DirectoryRequest) ReportExpiredSession(accounts *Accounts, result DirectoryResult) {
	accounts.ExpireSession(r.ref.Provider, r.session, result.err)
}

// Apply publishes only a result still owned by this root and session.
func (d *Directory) Apply(request *DirectoryRequest, result DirectoryResult) bool {
	if request == nil || d.requests[request.ref] != request || request.generation != d.generation || !sameDirectorySession(d.session, request.session) {
		return false
	}
	delete(d.requests, request.ref)
	request.cancel()
	if result.err != nil {
		if errors.Is(result.err, context.Canceled) {
			return true
		}
		branch := d.branches[request.ref]
		branch.err = result.err
		d.branches[request.ref] = branch
		return true
	}
	if request.ref != d.root {
		for _, entry := range result.branches[request.ref].children {
			if parent, exists := d.parents[entry.Ref]; entry.Ref == d.root || exists && parent != request.ref {
				d.branches[request.ref] = directoryBranch{err: errors.New("网盘返回了重复的文件身份。")}
				return true
			}
		}
	}
	selected := d.Selection()
	d.removeChildren(request.ref)
	for ref, branch := range result.branches {
		d.sortEntries(branch.children)
		d.branches[ref] = branch
		for _, entry := range branch.children {
			d.entries[entry.Ref] = entry
			d.parents[entry.Ref] = ref
		}
	}
	for ref := range d.expanded {
		if _, ok := d.entries[ref]; !ok {
			delete(d.expanded, ref)
		}
	}
	d.SetSelection(selected)
	return true
}

func (d *Directory) removeChildren(ref RemoteRef) {
	for _, entry := range d.branches[ref].children {
		d.removeChildren(entry.Ref)
		delete(d.entries, entry.Ref)
		delete(d.parents, entry.Ref)
	}
	delete(d.branches, ref)
}

func listRemote(ctx context.Context, session AccountSession, ref RemoteRef) ([]RemoteEntry, error) {
	switch {
	case ref.Provider == Baidu && session.Baidu != nil:
		entries, err := session.Baidu.ListDirectory(ctx, ref.Path)
		if err != nil {
			return nil, err
		}
		result := make([]RemoteEntry, len(entries))
		for i, entry := range entries {
			result[i] = fromBaidu(entry)
			if !validRemoteChild(ref, result[i]) {
				return nil, baidu.ErrInvalidResponse
			}
		}
		return result, nil
	case ref.Provider == Quark && session.Quark != nil:
		entries, err := session.Quark.ListDirectory(ctx, ref.ID)
		if err != nil {
			return nil, err
		}
		result := make([]RemoteEntry, len(entries))
		for i, entry := range entries {
			result[i] = RemoteEntry{Ref: RemoteRef{Provider: Quark, ID: entry.FID}, Name: entry.Name, IsDirectory: entry.IsDirectory,
				Size: entry.Size, ModifiedAt: entry.UpdatedAt, MD5: entry.MD5}
			if !validRemoteChild(ref, result[i]) {
				return nil, quark.ErrInvalidResponse
			}
		}
		return result, nil
	}
	return nil, errors.New("请重新登录网盘。")
}

func fromBaidu(entry baidu.Entry) RemoteEntry {
	return RemoteEntry{Ref: RemoteRef{Provider: Baidu, ID: strconv.FormatInt(entry.FSID, 10), Path: entry.Path},
		Name: entry.Name, IsDirectory: entry.IsDirectory, Size: entry.Size, ModifiedAt: entry.ModifiedAt}
}

func validRemoteChild(parent RemoteRef, entry RemoteEntry) bool {
	name := entry.Name
	if entry.Ref.Provider != parent.Provider || entry.Ref.ID == "" || entry.Ref == parent ||
		name == "" || name == "." || name == ".." || strings.ContainsAny(name, "/\x00") {
		return false
	}
	if parent.Provider == Baidu {
		prefix := strings.TrimSuffix(parent.Path, "/") + "/"
		candidate := norm.NFC.String(entry.Ref.Path)
		relative, inside := strings.CutPrefix(candidate, norm.NFC.String(prefix))
		return inside && relative == norm.NFC.String(name)
	}
	return entry.Ref != Quark.RootRef()
}
