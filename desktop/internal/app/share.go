package app

import (
	"context"
	"errors"
	"io/fs"
	"path"
	"regexp"
	"slices"
	"strings"

	"github.com/yjcdon/ferry-drive/desktop/internal/baidu"
	"github.com/yjcdon/ferry-drive/desktop/internal/quark"
)

var (
	ErrShareLink      = errors.New("请输入有效的百度或夸克网盘分享链接。")
	ErrShareCode      = errors.New("提取码应为 4 位字母或数字。")
	ErrShareAccount   = errors.New("请登录此分享链接所属的网盘。")
	ErrShareSelection = errors.New("请选择要下载的分享文件。")
)

var explicitShareCode = regexp.MustCompile(`^[A-Za-z0-9]{4}$`)

type ShareLink struct {
	Provider Provider
	URL      string
	Passcode string
}

func ParseShareInput(text, explicitCode string) (ShareLink, error) {
	explicitCode = strings.TrimSpace(explicitCode)
	if explicitCode != "" && !explicitShareCode.MatchString(explicitCode) {
		return ShareLink{}, ErrShareCode
	}
	if parsed, err := baidu.ParseShareLink(text); err == nil {
		if explicitCode == "" {
			explicitCode = parsed.Password
		}
		return ShareLink{Provider: Baidu, URL: parsed.URL(), Passcode: explicitCode}, nil
	}
	if parsed, err := quark.ParseShareLink(text); err == nil {
		if explicitCode == "" {
			explicitCode = parsed.Passcode
		}
		return ShareLink{Provider: Quark, URL: parsed.URL(), Passcode: explicitCode}, nil
	}
	return ShareLink{}, ErrShareLink
}

type shareAccess struct {
	session AccountSession
	link    ShareLink
	baidu   baidu.ShareSession
	quark   quark.ShareSession
	title   string
}

// ShareBrowser reuses directory expansion, sort and selection. Provider
// tokens stay private to the opened share.
type ShareBrowser struct {
	tree   *Directory
	access shareAccess
	nodes  map[RemoteRef]shareNode
	closed bool
}

type shareNode struct {
	entry    RemoteEntry
	relative string
	baidu    baidu.ShareEntry
	quark    quark.Entry
}

func OpenShare(ctx context.Context, accounts *Accounts, link ShareLink) (*ShareBrowser, error) {
	if link.Provider != Baidu && link.Provider != Quark {
		return nil, ErrShareLink
	}
	session := accounts.Session(link.Provider)
	access, err := openShareAccess(ctx, session, link)
	if err != nil {
		accounts.ExpireSession(link.Provider, session, err)
		return nil, err
	}
	if !sameDirectorySession(access.session, accounts.Session(link.Provider)) {
		return nil, ErrShareAccount
	}
	tree := NewDirectory(link.Provider)
	tree.SetSession(access.session)
	return &ShareBrowser{tree: tree, access: access, nodes: make(map[RemoteRef]shareNode)}, nil
}

func openShareAccess(ctx context.Context, session AccountSession, link ShareLink) (shareAccess, error) {
	a := shareAccess{session: session, link: link}
	if session.State != LoggedIn {
		return shareAccess{}, ErrShareAccount
	}
	switch {
	case link.Provider == Baidu && session.Baidu != nil:
		native, err := baidu.ParseShareLink(link.URL)
		if err != nil {
			return shareAccess{}, err
		}
		a.baidu, err = session.Baidu.OpenShare(ctx, native, link.Passcode)
		if err != nil {
			return shareAccess{}, err
		}
		a.title = "百度分享"
	case link.Provider == Quark && session.Quark != nil:
		native, err := quark.ParseShareLink(link.URL)
		if err != nil {
			return shareAccess{}, err
		}
		native.Passcode = link.Passcode
		a.quark, err = session.Quark.OpenShare(ctx, native)
		if err != nil {
			return shareAccess{}, err
		}
		a.title = a.quark.Title
	default:
		return shareAccess{}, ErrShareAccount
	}
	return a, nil
}

func (b *ShareBrowser) Tree() *Directory   { return b.tree }
func (b *ShareBrowser) Title() string      { return b.access.title }
func (b *ShareBrowser) Provider() Provider { return b.access.link.Provider }
func (b *ShareBrowser) Link() ShareLink    { return b.access.link }

func (b *ShareBrowser) Close() {
	b.tree.Close()
	b.closed = true
	clear(b.nodes)
	b.access = shareAccess{}
}

type ShareRequest struct {
	request *DirectoryRequest
	access  shareAccess
	parent  *shareNode
}

type SharePage struct {
	result DirectoryResult
	nodes  map[RemoteRef]shareNode
}

func (b *ShareBrowser) Refresh() *ShareRequest {
	if b.closed {
		return nil
	}
	request := b.tree.Refresh()
	if request == nil {
		return nil
	}
	return &ShareRequest{request: request, access: b.access}
}

func (b *ShareBrowser) Expand(ref RemoteRef) *ShareRequest {
	parent, ok := b.nodes[ref]
	if b.closed || !ok {
		return nil
	}
	request := b.tree.Expand(ref)
	if request == nil {
		return nil
	}
	return &ShareRequest{request: request, access: b.access, parent: &parent}
}

func (r *ShareRequest) Fetch(ctx context.Context) SharePage {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stop := context.AfterFunc(r.request.ctx, cancel)
	defer stop()
	page := SharePage{result: DirectoryResult{branches: make(map[RemoteRef]directoryBranch)}, nodes: make(map[RemoteRef]shareNode)}
	seen := map[RemoteRef]bool{r.request.ref: true}
	var visit func(ref RemoteRef, parent *shareNode) error
	visit = func(ref RemoteRef, parent *shareNode) error {
		children, err := r.access.list(ctx, parent)
		if err != nil {
			page.result.branches[ref] = directoryBranch{err: err}
			return err
		}
		entries := make([]RemoteEntry, 0, len(children))
		for _, node := range children {
			child := node.entry.Ref
			if seen[child] {
				return errors.New("分享返回了重复的文件身份。")
			}
			seen[child] = true
			page.nodes[child] = node
			entries = append(entries, node.entry)
		}
		page.result.branches[ref] = directoryBranch{children: entries}
		for _, node := range children {
			if node.entry.IsDirectory && r.request.expanded[node.entry.Ref] {
				if err := visit(node.entry.Ref, &node); err != nil {
					return err
				}
			}
		}
		return nil
	}
	page.result.err = visit(r.request.ref, r.parent)
	return page
}

func (b *ShareBrowser) Apply(request *ShareRequest, page SharePage) bool {
	if b.closed || request == nil || !b.tree.Apply(request.request, page.result) {
		return false
	}
	if page.result.err == nil && b.tree.LoadError(request.request.ref) == nil {
		for ref := range b.nodes {
			if _, ok := b.tree.Entry(ref); !ok {
				delete(b.nodes, ref)
			}
		}
		for ref, node := range page.nodes {
			b.nodes[ref] = node
		}
	}
	return true
}

func (a shareAccess) list(ctx context.Context, parent *shareNode) ([]shareNode, error) {
	var relative string
	if parent != nil {
		relative = parent.relative
	}
	var nodes []shareNode
	if a.link.Provider == Baidu {
		var native *baidu.ShareEntry
		if parent != nil {
			native = &parent.baidu
		}
		items, err := a.session.Baidu.ListShare(ctx, a.baidu, native)
		if err != nil {
			return nil, err
		}
		for _, item := range items {
			nodes = append(nodes, shareNode{entry: fromBaidu(item.Entry), baidu: item})
		}
	} else {
		fid := quark.RootFID
		if parent != nil {
			fid = parent.quark.FID
		}
		items, err := a.session.Quark.ListShareDirectory(ctx, a.quark, fid)
		if err != nil {
			return nil, err
		}
		for _, item := range items {
			nodes = append(nodes, shareNode{entry: RemoteEntry{Ref: RemoteRef{Provider: Quark, ID: item.FID},
				Name: item.Name, Size: item.Size, IsDirectory: item.IsDirectory, ModifiedAt: item.UpdatedAt, MD5: item.MD5}, quark: item})
		}
	}
	for i := range nodes {
		n := &nodes[i]
		if !shareName(n.entry.Name) || n.entry.Size < 0 || n.entry.Ref.ID == "" || n.entry.Ref.ID == "0" {
			return nil, errors.New("分享返回了无效的文件条目。")
		}
		n.relative = path.Join(relative, n.entry.Name)
		if n.entry.Ref.Provider == Baidu {
			n.baidu.RelativeDirectory = relative
		}
	}
	return nodes, nil
}

func shareName(name string) bool {
	return fs.ValidPath(name) && name != "." && !strings.ContainsAny(name, "/\x00")
}

type shareAnchor struct {
	Relative string
	Parents  []RemoteEntry
	Entry    RemoteEntry
}

type ShareSelection struct {
	access  shareAccess
	anchors []shareAnchor
}

func (s ShareSelection) Provider() Provider { return s.access.link.Provider }
func (s ShareSelection) AccountID() string  { return s.access.session.ID }
func (s ShareSelection) Title() string      { return s.access.title }

// Selection freezes deduplicated visible selection and source ancestry.
func (b *ShareBrowser) Selection() (ShareSelection, error) {
	if b.closed {
		return ShareSelection{}, ErrShareSelection
	}
	selection := ShareSelection{access: b.access}
	for _, selected := range b.tree.SelectedEntries() {
		node, ok := b.nodes[selected.Ref]
		if !ok {
			return ShareSelection{}, ErrShareSelection
		}
		var parents []RemoteEntry
		for parent := b.tree.parents[selected.Ref]; parent != b.tree.root; parent = b.tree.parents[parent] {
			entry, ok := b.tree.Entry(parent)
			if !ok {
				return ShareSelection{}, ErrShareSelection
			}
			parents = append(parents, entry)
		}
		slices.Reverse(parents)
		selection.anchors = append(selection.anchors, shareAnchor{Relative: node.relative, Parents: parents, Entry: selected})
	}
	if len(selection.anchors) == 0 {
		return ShareSelection{}, ErrShareSelection
	}
	return selection, nil
}
