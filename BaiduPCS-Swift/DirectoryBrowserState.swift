import FerryCore
import Foundation
import Observation

/// 文件操作的确认上下文；目录展开或页面刷新不能改变已经冻结的目标。
struct DirectoryContext {
    let account: AccountKey
    let session: ObjectIdentifier
    let reference: RemoteReference
    let trail: [RemoteEntry]
    let hasUnknownAncestors: Bool

    var provider: Provider { account.provider }
    var pathDescription: String {
        if reference == provider.rootReference { return "根目录" }
        let names = trail.map(\.name).joined(separator: " / ")
        return "根目录 / " + (hasUnknownAncestors ? "… / " : "") + names
    }
}

/// 每家网盘保留当前列表根和已展开的子树；仅用户展开时读取子目录。
@Observable
final class DirectoryBrowserState {
    enum Sort: String, CaseIterable, Identifiable {
        case name, modified, size
        var id: Self { self }
        var title: String {
            switch self { case .name: "名称"; case .modified: "修改日期"; case .size: "大小" }
        }
    }

    let provider: Provider
    private(set) var account: AccountKey?
    private(set) var session: ObjectIdentifier?
    private(set) var tree: FileTree<RemoteEntry>?
    private(set) var trail: [RemoteEntry] = []
    private(set) var hasUnknownAncestors = false
    private(set) var generation = 0
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var focusedReference: RemoteReference?
    var query = "" {
        didSet { if query != oldValue { pruneInvisibleSelection() } }
    }
    var sort: Sort = .name
    var descending = false
    /// 主窗口用它避免在文件操作确认尚未结束时另开上传或下载面板。
    var isOperationPresented = false
    @ObservationIgnored private var didResolveAccount = false
    @ObservationIgnored private var requestID: UUID?

    private struct SavedLocation: Codable {
        let account: AccountKey
        let trail: [RemoteEntry]
        let hasUnknownAncestors: Bool
    }

    init(provider: Provider) { self.provider = provider }

    var currentDirectory: RemoteReference { trail.last?.reference ?? provider.rootReference }
    var context: DirectoryContext? {
        guard let account, let session, tree != nil, !isLoading, errorMessage == nil else { return nil }
        return .init(account: account, session: session, reference: currentDirectory,
                     trail: trail, hasUnknownAncestors: hasUnknownAncestors)
    }
    var selectedEntries: [RemoteEntry] { tree?.selectedEntries ?? [] }
    var canGoUp: Bool { !trail.isEmpty && (!hasUnknownAncestors || trail.count > 1) }

    /// 当前根的搜索只筛选直接子项，不为搜索递归访问未展开目录。
    var rootNodes: [FileNode<RemoteEntry>] {
        guard let tree else { return [] }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return orderedChildren(tree.root).filter {
            text.isEmpty || $0.entry?.name.localizedCaseInsensitiveContains(text) == true
        }
    }

    /// 同级排序维持树形层次，同值使用名称和准确引用作稳定比较。
    func orderedChildren(_ node: FileNode<RemoteEntry>) -> [FileNode<RemoteEntry>] {
        (node.children ?? []).sorted { lhs, rhs in
            guard let a = lhs.entry, let b = rhs.entry else { return false }
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            var result: ComparisonResult
            switch sort {
            case .name: result = a.name.localizedStandardCompare(b.name)
            case .modified:
                if a.modifiedAt == nil, b.modifiedAt != nil { return false }
                if a.modifiedAt != nil, b.modifiedAt == nil { return true }
                result = a.modifiedAt == b.modifiedAt ? .orderedSame :
                    ((a.modifiedAt ?? .distantPast) < (b.modifiedAt ?? .distantPast) ? .orderedAscending : .orderedDescending)
            case .size:
                result = a.size == b.size || a.isDirectory ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            }
            if result == .orderedSame { result = a.name.localizedStandardCompare(b.name) }
            if result == .orderedSame { return a.reference.identifier < b.reference.identifier }
            return descending ? result == .orderedDescending : result == .orderedAscending
        }
    }

    /// 搜索和收起时仅清除不可见的独立勾选，父目录整体选择仍然有效。
    func pruneInvisibleSelection() {
        guard let tree else { return }
        var ids = Set<String>()
        func collect(_ nodes: [FileNode<RemoteEntry>]) {
            for node in nodes {
                if let id = node.id { ids.insert(id) }
                if query.isEmpty, node.isExpanded { collect(node.children ?? []) }
            }
        }
        collect(rootNodes)
        tree.retainSelection(in: ids)
    }

    func clearSelection() { tree?.retainSelection(in: []) }
    func selectAll() {
        guard !isLoading else { return }
        tree?.selectTopLevel(rootNodes)
    }
    func refresh() { generation += 1 }

    func revealCreated(_ entry: RemoteEntry) {
        focusedReference = entry.reference
        refresh()
    }

    /// 进入目录改变列表根；单纯展开目录不调用此方法。
    func enter(_ entry: RemoteEntry) {
        guard entry.isDirectory, let path = path(to: entry.reference) else { return }
        navigate(to: trail + path)
    }

    func navigate(to path: [RemoteEntry]) {
        trail = path
        if path.isEmpty { hasUnknownAncestors = false }
        query = ""; tree = nil; errorMessage = nil; focusedReference = nil
        saveLocation(); refresh()
    }

    /// 准确云端引用可以缺少祖先；这种定位不伪造上一级关系。
    func open(account: AccountKey, directory: RemoteReference, trail path: [RemoteEntry]? = nil,
              focus: RemoteReference? = nil) {
        guard account.provider == provider, directory.provider == provider else { return }
        self.account = account; didResolveAccount = true
        if directory == provider.rootReference {
            trail = []; hasUnknownAncestors = false
        } else if let path, path.last?.reference == directory {
            trail = path; hasUnknownAncestors = false
        } else {
            let name: String
            if case .baidu(let value, _) = directory { name = (value as NSString).lastPathComponent }
            else { name = "已定位目录" }
            trail = [.init(reference: directory, name: name, isDirectory: true, size: 0)]
            hasUnknownAncestors = true
        }
        query = ""; tree = nil; errorMessage = nil; focusedReference = focus
        saveLocation(); refresh()
    }

    /// 从当前树取得条目的真实祖先，跨层批量操作不能都使用列表根作为父目录。
    func path(to reference: RemoteReference) -> [RemoteEntry]? {
        guard let tree else { return nil }
        func visit(_ node: FileNode<RemoteEntry>, _ ancestors: [RemoteEntry]) -> [RemoteEntry]? {
            let path = ancestors + (node.entry.map { [$0] } ?? [])
            if node.entry?.reference == reference { return path }
            for child in node.children ?? [] {
                if let result = visit(child, path) { return result }
            }
            return nil
        }
        return visit(tree.root, [])
    }

    func context(for entry: RemoteEntry) -> DirectoryContext? {
        guard let context, entry.isDirectory, let path = path(to: entry.reference) else { return nil }
        return .init(account: context.account, session: context.session, reference: entry.reference,
                     trail: trail + path, hasUnknownAncestors: hasUnknownAncestors)
    }

    /// 请求由可见文件页的 task 驱动；旧会话或旧树的返回永远不发布到当前页面。
    func load(model: AppModel) async {
        guard let disk = model.coordinator.netdisks[provider] else {
            account = nil; session = nil; tree = nil; trail = []; hasUnknownAncestors = false
            query = ""; errorMessage = nil; isLoading = false; requestID = nil; focusedReference = nil
            return
        }
        let key = disk.account
        if account != key {
            tree = nil; trail = []; hasUnknownAncestors = false; query = ""; focusedReference = nil
            if !didResolveAccount, let data = UserDefaults.standard.data(forKey: preferenceKey),
               let saved = try? JSONDecoder().decode(SavedLocation.self, from: data), saved.account == key,
               saved.trail.allSatisfy({ $0.isDirectory && $0.reference.provider == provider }) {
                trail = saved.trail; hasUnknownAncestors = saved.hasUnknownAncestors
            }
            didResolveAccount = true; account = key
        }
        let identity = ObjectIdentifier(disk)
        if session != identity { tree = nil; session = identity }
        let id = UUID(); requestID = id
        let treeGeneration = generation
        let directory = currentDirectory
        let previous = tree
        let expanded = expandedReferences(previous?.root)
        isLoading = true; errorMessage = nil
        defer { if requestID == id { isLoading = false; requestID = nil } }
        do {
            let environment = try model.uploadEnvironment(for: key)
            let next = FileTree<RemoteEntry>(initialSelection: .none, list: { [weak self, weak model] entry in
                guard let self, let model else { throw CancellationError() }
                guard self.generation == treeGeneration, self.account == key, self.session == identity,
                      model.accountKey(for: self.provider) == key,
                      model.coordinator.netdisks[self.provider].map(ObjectIdentifier.init) == identity else {
                    throw CancellationError()
                }
                let entries = try await environment.listDirectory(entry?.reference ?? directory)
                try Task.checkCancellation()
                guard self.generation == treeGeneration, self.account == key, self.session == identity, self.currentDirectory == directory,
                      model.coordinator.netdisks[self.provider].map(ObjectIdentifier.init) == identity else {
                    throw CancellationError()
                }
                return entries
            }, onError: { _ in })
            await next.load(next.root)
            try Task.checkCancellation()
            guard requestID == id, currentDirectory == directory, session == identity else { return }
            guard next.root.children != nil else {
                errorMessage = next.root.loadError ?? "目录读取未完成，请重试。"
                return
            }
            await restoreExpanded(expanded, in: next.root, tree: next)
            try Task.checkCancellation()
            guard requestID == id, currentDirectory == directory, session == identity else { return }
            let selected = Set((previous?.selectedEntries ?? []).map(\.reference))
            tree = next
            for node in allNodes(next.root) where node.entry.map({ selected.contains($0.reference) }) == true {
                next.setSelected(node, true)
            }
            if let focus = focusedReference, let node = next.root.children?.first(where: { $0.entry?.reference == focus }) {
                next.setSelected(node, true)
            }
            focusedReference = nil
            pruneInvisibleSelection(); saveLocation()
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            errorMessage = error.localizedDescription
        }
    }

    private var preferenceKey: String { "workspace.directory.v1." + provider.rawValue }

    private func saveLocation() {
        guard let account else { return }
        let saved = SavedLocation(account: account, trail: trail, hasUnknownAncestors: hasUnknownAncestors)
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: preferenceKey) }
    }

    private func allNodes(_ node: FileNode<RemoteEntry>) -> [FileNode<RemoteEntry>] {
        (node.children ?? []).flatMap { [$0] + allNodes($0) }
    }

    private func expandedReferences(_ node: FileNode<RemoteEntry>?) -> Set<RemoteReference> {
        guard let node else { return [] }
        return Set(allNodes(node).filter(\.isExpanded).compactMap { $0.entry?.reference })
    }

    private func restoreExpanded(_ references: Set<RemoteReference>, in node: FileNode<RemoteEntry>,
                                 tree: FileTree<RemoteEntry>) async {
        for child in node.children ?? [] where child.entry.map({ references.contains($0.reference) }) == true {
            guard !Task.isCancelled else { return }
            child.isExpanded = true
            await tree.load(child)
            await restoreExpanded(references, in: child, tree: tree)
        }
    }
}
