import AppKit
import FerryCore
import Observation
import SwiftUI

/// 文件页拥有名称与提交状态；原生表格只负责指定条目的行内输入和焦点。
struct FileNameEditing {
    let reference: RemoteReference
    let name: String
    let error: String?
    let isSubmitting: Bool
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
}

/// 文件工作区的原生树表：列、焦点与拖放由 AppKit 管理，目录与勾选仍属于文件树。
struct NetdiskOutlineView: NSViewRepresentable {
    let browser: DirectoryBrowserState
    let tree: FileTree<RemoteEntry>
    let transferFolder: String
    let allowsUpload: Bool
    let onUpload: (RemoteEntry?, [URL]) -> Bool
    let onDownload: (RemoteEntry) -> Void
    let onRename: (RemoteEntry) -> Void
    let onDelete: (RemoteEntry) -> Void
    let onNewFolder: (() -> Void)?
    var nameEditing: FileNameEditing? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FileListScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let table = FileOutline()
        table.backgroundColor = .textBackgroundColor
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 8, height: 1)
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = .separatorColor
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = true
        table.indentationPerLevel = 18
        table.autosaveTableColumns = false
        table.autoresizesOutlineColumn = false
        table.headerView = NSTableHeaderView()
        for (id, title, width, minimum) in [("name", "名称", 320.0, 180.0),
                                          ("modified", "修改日期", 200.0, 100.0), ("size", "大小", 90.0, 60.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.minWidth = minimum
            column.maxWidth = id == "name" ? 4000 : 600
            let saved = AppPreferences.defaults.double(forKey: "workspace.columns.v1." + id)
            column.width = saved.isFinite && saved >= minimum ? min(saved, column.maxWidth) : width
            column.resizingMask = .userResizingMask
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        table.outlineTableColumn = table.tableColumns.first
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openFocused)
        table.registerForDraggedTypes([.fileURL])
        table.onSpace = { [weak coordinator = context.coordinator] in coordinator?.toggleFocused() }
        table.onOpen = { [weak coordinator = context.coordinator] in coordinator?.openSelected() }
        table.onGoUp = { [weak browser] in
            guard let browser, browser.canGoUp else { return }
            browser.navigate(to: Array(browser.trail.dropLast()))
        }
        table.onMenu = { [weak coordinator = context.coordinator] row in coordinator?.menu(for: row) }
        scroll.documentView = table
        scroll.onColumnLayout = { [weak coordinator = context.coordinator] width in
            coordinator?.layoutColumns(in: width)
        }
        context.coordinator.table = table
        context.coordinator.refresh()
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.updateInput(self)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.stop()
        (view as? FileListScrollView)?.onColumnLayout = nil
        (view.documentView as? NSOutlineView)?.delegate = nil
        (view.documentView as? NSOutlineView)?.dataSource = nil
    }

    /// 原生代理保存展示映射和观察任务；界面销毁后释放回调及加载任务。
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var input: NetdiskOutlineView
        weak var table: FileOutline?
        private var children: [ObjectIdentifier: [AnyObject]] = [:]
        private var roots: [AnyObject] = []
        private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        private var observation = UUID()
        private var isUpdating = false
        private weak var renderedTree: FileTree<RemoteEntry>?
        private var stopped = false
        private var menuEntry: RemoteEntry?
        private var isMenuTracking = false
        private var renameAfterMenu: RemoteEntry?
        private var isAdjustingColumns = false
        private weak var editingCell: NameCell?
        private var editingReference: RemoteReference?
        private var widthAnchor: ColumnWidthAnchor?
        private struct ColumnWidthAnchor {
            let name: CGFloat
            let viewport: CGFloat
        }
        private static let formatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter
        }()

        init(_ input: NetdiskOutlineView) {
            self.input = input
            let name = CGFloat(AppPreferences.defaults.double(forKey: "workspace.columns.v1.name"))
            let viewport = CGFloat(AppPreferences.defaults.double(forKey: "workspace.columns.v1.viewport"))
            if name.isFinite, name >= 180, viewport.isFinite, viewport > 0 {
                widthAnchor = .init(name: min(name, 4000), viewport: viewport)
            }
        }

        /// SwiftUI 更新只替换动作与可用性；业务变化由已有的一次性观察触发。
        func updateInput(_ input: NetdiskOutlineView) {
            let changesBadge = self.input.transferFolder != input.transferFolder
            let previous = self.input.nameEditing
            self.input = input
            if changesBadge { render() }
            else {
                let errorChanged = previous?.error != input.nameEditing?.error
                if errorChanged, let table {
                    let affected = [previous?.reference, input.nameEditing?.reference].compactMap { $0 }
                    let rows = (0..<table.numberOfRows).filter { row in
                        guard let entry = (table.item(atRow: row) as? FileNode<RemoteEntry>)?.entry else { return false }
                        return affected.contains(entry.reference)
                    }
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(rows))
                }
                updateNameEditing(refocus: errorChanged && input.nameEditing?.error != nil)
            }
        }

        /// 窗口宽度始终相对用户拖动锚点计算，临时窄布局的最小宽度保持局部。
        func layoutColumns(in width: CGFloat) {
            guard !isAdjustingColumns, width > 0, let table, let name = table.tableColumns.first else { return }
            let proposed = widthAnchor.map { $0.name + width - $0.viewport } ??
                (width - table.tableColumns.dropFirst().reduce(0) { $0 + $1.width } - table.intercellSpacing.width * 3)
            isAdjustingColumns = true
            defer { isAdjustingColumns = false }
            name.width = min(name.maxWidth, max(name.minWidth, proposed))
            table.sizeToFit()
        }

        /// 一次性观察覆盖已加载子树；每次变化合并到主线程下一次刷新，空闲时没有轮询。
        func refresh() {
            guard !stopped, table != nil, input.browser.tree === input.tree else { return }
            let token = UUID()
            observation = token
            children.removeAll(keepingCapacity: true)
            withObservationTracking {
                _ = input.tree.selection
                _ = input.browser.query
                _ = input.browser.sort
                _ = input.browser.descending
                _ = input.browser.focusedReference
                let rootNodes = input.browser.rootNodes
                roots = rootNodes
                @MainActor func collect(_ node: FileNode<RemoteEntry>) {
                    _ = node.isExpanded
                    _ = node.isLoading
                    _ = node.loadError
                    let loaded = input.browser.orderedChildren(node)
                    if node.children == nil, node.isDirectory {
                        children[ObjectIdentifier(node)] = [Placeholder(node)]
                    } else {
                        children[ObjectIdentifier(node)] = loaded
                        if node.isExpanded {
                            for child in loaded { collect(child) }
                        }
                    }
                }
                for node in rootNodes { collect(node) }
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.observation == token else { return }
                    self.refresh()
                }
            }
            render()
        }

        /// 表格渲染使用当前快照，程序性展开与焦点恢复保持独立于用户动作。
        private func render() {
            guard !stopped, let table, !isUpdating else { return }
            isUpdating = true
            defer { isUpdating = false }
            let highlighted = renderedTree === input.tree ? Set(table.selectedRowIndexes.compactMap {
                (table.item(atRow: $0) as? FileNode<RemoteEntry>)?.entry?.reference
            }) : []
            renderedTree = input.tree
            let hadEditor = editingCell?.label.currentEditor() != nil
            let selection = (editingCell?.label.currentEditor() as? NSTextView)?.selectedRange()
            editingCell?.stopEditing()
            editingCell = nil
            let sort = input.browser.sort.rawValue
            table.sortDescriptors = [NSSortDescriptor(key: sort, ascending: !input.browser.descending)]
            table.reloadData()
            if input.browser.query.isEmpty {
                @MainActor func expand(_ nodes: [AnyObject]) {
                    for case let node as FileNode<RemoteEntry> in nodes where node.isExpanded {
                        table.expandItem(node)
                        expand(children[ObjectIdentifier(node)] ?? [])
                    }
                }
                expand(roots)
            }
            let reference = input.browser.focusedReference ?? input.browser.focusedRowReference
            let matchingRow = reference.flatMap { reference in
                (0..<table.numberOfRows).first(where: {
                   (table.item(atRow: $0) as? FileNode<RemoteEntry>)?.entry?.reference == reference
                })
            }
            let row = matchingRow ?? input.browser.focusedRowIndex.flatMap { previous in
                (0..<table.numberOfRows).filter { table.item(atRow: $0) is FileNode<RemoteEntry> }
                    .min { abs($0 - previous) < abs($1 - previous) }
            }
            if let row,
               let entry = (table.item(atRow: row) as? FileNode<RemoteEntry>)?.entry {
                let retainedRows = IndexSet((0..<table.numberOfRows).filter { index in
                    guard let reference = (table.item(atRow: index) as? FileNode<RemoteEntry>)?.entry?.reference else { return false }
                    return highlighted.contains(reference)
                })
                table.selectRowIndexes(input.browser.focusedReference != nil || retainedRows.isEmpty
                                       ? IndexSet(integer: row) : retainedRows, byExtendingSelection: false)
                input.browser.rememberFocus(entry.reference, row: row)
                if let requested = input.browser.focusedReference, entry.reference == requested {
                    table.scrollRowToVisible(row)
                    input.browser.consumeFocus(requested)
                }
            } else if table.numberOfRows == 0 {
                input.browser.rememberFocus(nil, row: nil)
            }
            updateNameEditing(refocus: hadEditor, selection: selection)
        }

        /// 名称变化只更新对应输入框；仅初次编辑、恢复刷新和错误反馈请求焦点。
        private func updateNameEditing(refocus: Bool = false, selection: NSRange? = nil) {
            guard !stopped, let table else { return }
            guard let editing = input.nameEditing else {
                editingCell?.stopEditing()
                editingCell = nil
                editingReference = nil
                return
            }
            guard let row = (0..<table.numberOfRows).first(where: {
                (table.item(atRow: $0) as? FileNode<RemoteEntry>)?.entry?.reference == editing.reference
            }) else {
                editingCell?.stopEditing()
                editingCell = nil
                editingReference = nil
                // 对象已加载但被搜索或折叠隐藏时结束编辑；新建条目尚未刷新则继续等待。
                if input.browser.path(to: editing.reference) != nil,
                   !input.browser.isLoading, !editing.isSubmitting {
                    Task { @MainActor [weak self] in
                        guard let self, !self.stopped, let table = self.table,
                              let current = self.input.nameEditing, current.reference == editing.reference,
                              !current.isSubmitting, !self.input.browser.isLoading,
                              self.input.browser.path(to: current.reference) != nil,
                              !(0..<table.numberOfRows).contains(where: {
                                  (table.item(atRow: $0) as? FileNode<RemoteEntry>)?.entry?.reference == current.reference
                              }) else { return }
                        current.onCancel()
                    }
                }
                return
            }
            let begins = editingReference != editing.reference
            if begins { table.scrollRowToVisible(row) }
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NameCell else { return }
            let replacesCell = editingCell !== cell
            if replacesCell { editingCell?.stopEditing() }
            editingCell = cell
            editingReference = editing.reference
            cell.configure(editing: editing)
            cell.onNameChange = { [weak self, weak cell] name in
                guard let self, !self.stopped, !self.isUpdating, self.editingCell === cell,
                      self.input.nameEditing?.reference == editing.reference else { return }
                self.input.nameEditing?.onChange(name)
            }
            cell.onNameSubmit = { [weak self, weak cell] in
                guard let self, !self.stopped, !self.isUpdating, self.editingCell === cell,
                      let current = self.input.nameEditing, current.reference == editing.reference,
                      !current.isSubmitting else { return }
                current.onSubmit()
                // 无效输入仍保持可继续修改；成功或提交中由最新状态结束输入。
                Task { @MainActor [weak self] in
                    guard let self, self.input.nameEditing?.error != nil else { return }
                    self.updateNameEditing(refocus: true)
                }
            }
            cell.onNameCancel = { [weak self, weak cell] in
                guard let self, !self.stopped, !self.isUpdating, self.editingCell === cell,
                      let current = self.input.nameEditing, current.reference == editing.reference,
                      !current.isSubmitting else { return }
                cell?.stopEditing()
                current.onCancel()
            }
            if begins || refocus || replacesCell {
                Task { @MainActor [weak self, weak cell] in
                    guard let self, !self.stopped, self.editingCell === cell,
                          let current = self.input.nameEditing, current.reference == editing.reference,
                          !current.isSubmitting else { return }
                    cell?.focusName(selection: selection, selectAll: begins || (replacesCell && selection == nil))
                }
            }
        }

        func stop() {
            stopped = true
            renameAfterMenu = nil
            editingCell?.stopEditing()
            editingCell = nil
            editingReference = nil
            observation = UUID()
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
            children.removeAll()
            roots.removeAll()
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            item.map { children[ObjectIdentifier($0 as AnyObject)]?.count ?? 0 } ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let values = item.map { children[ObjectIdentifier($0 as AnyObject)] ?? [] } ?? roots
            return values[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            input.browser.query.isEmpty && (item as? FileNode<RemoteEntry>)?.isDirectory == true
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            input.browser.query.isEmpty && (item as? FileNode<RemoteEntry>)?.isDirectory == true
        }

        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            item is FileNode<RemoteEntry>
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isUpdating, let node = notification.userInfo?["NSObject"] as? FileNode<RemoteEntry> else { return }
            node.isExpanded = true
            if node.children == nil { load(node) }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isUpdating, let node = notification.userInfo?["NSObject"] as? FileNode<RemoteEntry> else { return }
            node.isExpanded = false
            input.tree.discardDescendantSelection(of: node)
        }

        private func load(_ node: FileNode<RemoteEntry>) {
            let key = ObjectIdentifier(node)
            guard tasks[key] == nil else { return }
            let tree = input.tree
            tasks[key] = Task { @MainActor [weak self] in
                await tree.load(node)
                self?.tasks[key] = nil
            }
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            if let placeholder = item as? Placeholder {
                guard tableColumn?.identifier.rawValue == "name" else { return nil }
                let button = RetryButton(title: placeholder.node.loadError == nil ? "加载中" : "重试", target: self,
                                         action: #selector(retry(_:)))
                button.node = placeholder.node
                button.isBordered = false
                button.isEnabled = placeholder.node.loadError != nil
                button.toolTip = placeholder.node.loadError
                return button
            }
            guard let node = item as? FileNode<RemoteEntry>, let entry = node.entry else { return nil }
            if tableColumn?.identifier.rawValue == "name" {
                let cell = NameCell()
                var parent = outlineView.parent(forItem: node) as? FileNode<RemoteEntry>
                var inherited = false
                while let value = parent {
                    if input.tree.isSelected(value) { inherited = true; break }
                    parent = outlineView.parent(forItem: value) as? FileNode<RemoteEntry>
                }
                cell.checkbox.state = inherited || input.tree.isSelected(node) ? .on : .off
                cell.checkbox.image = NSImage(systemSymbolName: cell.checkbox.state == .on ? "checkmark.square.fill" : "square",
                                              accessibilityDescription: nil)
                cell.checkbox.contentTintColor = cell.checkbox.state == .on ? .controlAccentColor : .secondaryLabelColor
                cell.checkbox.isEnabled = !inherited
                cell.checkbox.setAccessibilityLabel("选择\(entry.name)")
                cell.checkbox.setAccessibilityHelp(inherited ? "随父文件夹一起选择" : "用于批量操作")
                cell.onToggle = { [weak self, weak node] in
                    guard let self, let node else { return }
                    self.input.tree.setSelected(node, !self.input.tree.isSelected(node))
                }
                cell.icon.image = NSImage(systemSymbolName: entry.isDirectory ? "folder" : "doc", accessibilityDescription: nil)
                cell.icon.contentTintColor = entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
                cell.label.stringValue = entry.name
                cell.label.toolTip = entry.name
                cell.setAccessibilityLabel(entry.name)
                if entry.isDirectory, input.browser.provider == .baidu,
                   RemotePath.normalized(entry.path) == RemotePath.normalized(input.transferFolder) {
                    cell.label.stringValue += "  转存目录"
                }
                return cell
            }
            let label = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "modified"
                ? entry.modifiedAt.map(Self.formatter.string(from:)) ?? "—"
                : entry.isDirectory ? "—" : entry.size.byteCount)
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = tableColumn?.identifier.rawValue == "size" ? .right : .left
            label.lineBreakMode = .byTruncatingTail
            let cell = NSTableCellView()
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            cell.textField = label
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let editing = input.nameEditing, editing.error != nil,
                  (item as? FileNode<RemoteEntry>)?.entry?.reference == editing.reference else { return 30 }
            return 50
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isUpdating, let sort = outlineView.sortDescriptors.first,
                  let key = sort.key, let field = DirectoryBrowserState.Sort(rawValue: key) else { return }
            input.browser.sort = field
            input.browser.descending = !sort.ascending
        }

        func outlineViewColumnDidResize(_ notification: Notification) {
            guard !isAdjustingColumns, let table, let name = table.tableColumns.first,
                  let scroll = table.enclosingScrollView as? FileListScrollView else { return }
            let viewportWidth = scroll.contentView.bounds.width
            guard viewportWidth > 0 else { return }
            widthAnchor = .init(name: name.width, viewport: viewportWidth)
            for column in table.tableColumns {
                AppPreferences.defaults.set(column.width, forKey: "workspace.columns.v1." + column.identifier.rawValue)
            }
            AppPreferences.defaults.set(viewportWidth, forKey: "workspace.columns.v1.viewport")
            scroll.requestColumnLayout()
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            item is FileNode<RemoteEntry> || (item as? Placeholder)?.node.loadError != nil
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let table else { return }
            let row = table.selectedRow
            let entry = (table.item(atRow: row) as? FileNode<RemoteEntry>)?.entry
            input.browser.rememberFocus(entry?.reference, row: entry == nil ? nil : row)
        }

        @objc func openFocused() {
            guard let table, let entry = (table.item(atRow: table.clickedRow) as? FileNode<RemoteEntry>)?.entry else { return }
            if entry.isDirectory { input.browser.enter(entry) }
        }

        /// 键盘打开使用当前行焦点，和勾选集合保持独立。
        func openSelected() {
            guard let table, let entry = (table.item(atRow: table.selectedRow) as? FileNode<RemoteEntry>)?.entry else { return }
            if entry.isDirectory { input.browser.enter(entry) }
        }

        func toggleFocused() {
            guard let table, let node = table.item(atRow: table.selectedRow) as? FileNode<RemoteEntry> else { return }
            var parent = table.parent(forItem: node) as? FileNode<RemoteEntry>
            while let value = parent {
                if input.tree.isSelected(value) { return }
                parent = table.parent(forItem: value) as? FileNode<RemoteEntry>
            }
            input.tree.setSelected(node, !input.tree.isSelected(node))
        }

        @objc private func retry(_ sender: RetryButton) {
            if let node = sender.node { load(node) }
        }

        func menu(for row: Int) -> NSMenu? {
            menuEntry = nil
            if row == -1 {
                guard input.onNewFolder != nil else { return nil }
                let menu = NSMenu()
                menu.delegate = self
                let item = NSMenuItem(title: "新建文件夹", action: #selector(newFolder), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
                return menu
            }
            guard input.allowsUpload, let table,
                  let entry = (table.item(atRow: row) as? FileNode<RemoteEntry>)?.entry else { return nil }
            menuEntry = entry
            let menu = NSMenu()
            menu.delegate = self
            for (title, action) in [("下载", #selector(download)), ("上传到此文件夹", #selector(upload)),
                                    ("重命名", #selector(rename)), ("移到回收站", #selector(deleteEntry))] {
                if action == #selector(upload), !entry.isDirectory { continue }
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            return menu
        }

        @objc private func newFolder() { input.onNewFolder?() }
        @objc private func download() { if let menuEntry { input.onDownload(menuEntry) } }
        @objc private func upload() { if let menuEntry { _ = input.onUpload(menuEntry, []) } }
        /// 菜单先完成焦点归还，再让行内编辑取得焦点，避免立刻收到离焦提交。
        @objc private func rename() {
            guard let menuEntry else { return }
            if isMenuTracking { renameAfterMenu = menuEntry }
            else { beginRenameAfterMenu(menuEntry) }
        }

        func menuWillOpen(_ menu: NSMenu) { isMenuTracking = true }

        func menuDidClose(_ menu: NSMenu) {
            isMenuTracking = false
            guard let entry = renameAfterMenu else { return }
            renameAfterMenu = nil
            beginRenameAfterMenu(entry)
        }

        private func beginRenameAfterMenu(_ entry: RemoteEntry) {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.input.onRename(entry)
            }
        }
        @objc private func deleteEntry() { if let menuEntry { input.onDelete(menuEntry) } }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard input.allowsUpload,
                  info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return [] }
            let node = item as? FileNode<RemoteEntry>
            outlineView.setDropItem(node?.isDirectory == true ? node : nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            guard input.allowsUpload, !urls.isEmpty else { return false }
            return input.onUpload((item as? FileNode<RemoteEntry>)?.entry, urls)
        }
    }
}
private final class Placeholder {
    let node: FileNode<RemoteEntry>
    init(_ node: FileNode<RemoteEntry>) { self.node = node }
}

private final class RetryButton: NSButton {
    weak var node: FileNode<RemoteEntry>?
}

/// 视口及用户列宽变化交给正常布局阶段合并，表格代理只记录用户锚点。
private final class FileListScrollView: NSScrollView {
    var onColumnLayout: ((CGFloat) -> Void)?
    private var viewportWidth: CGFloat = 0
    private var columnLayoutPending = false

    override func tile() {
        super.tile()
        let width = contentView.bounds.width
        if width > 0, width != viewportWidth {
            viewportWidth = width
            requestColumnLayout()
        }
    }

    /// 标记下一次列布局，由 AppKit 布局周期读取最新视口宽度。
    func requestColumnLayout() {
        columnLayoutPending = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if columnLayoutPending, contentView.bounds.width > 0 {
            columnLayoutPending = false
            onColumnLayout?(contentView.bounds.width)
        }
    }
}

/// 行焦点的空格操作与右键位置由原生表格派发，文本编辑继续使用系统按键。
final class FileOutline: NSOutlineView {
    var onSpace: (() -> Void)?
    var onOpen: (() -> Void)?
    var onGoUp: (() -> Void)?
    var onMenu: ((Int) -> NSMenu?)?
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command, event.keyCode == 126 {
            onGoUp?()
        } else if modifiers == .command, event.keyCode == 125 {
            onOpen?()
        } else if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            onOpen?()
        } else if event.charactersIgnoringModifiers == " ", modifiers.isEmpty {
            onSpace?()
        } else { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

private final class NameCell: NSTableCellView, NSTextFieldDelegate {
    let checkbox = NSButton(title: "", target: nil, action: nil)
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private var editing = false
    private var suppressEndEditing = false
    private var originalName = ""
    private var pendingFocus: (selection: NSRange?, selectAll: Bool)?
    private var isApplyingFocus = false
    var onToggle: (() -> Void)?
    var onNameChange: ((String) -> Void)?
    var onNameSubmit: (() -> Void)?
    var onNameCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        checkbox.target = self
        checkbox.action = #selector(toggle)
        checkbox.setButtonType(.toggle)
        checkbox.isBordered = false
        checkbox.imagePosition = .imageOnly
        checkbox.imageScaling = .scaleProportionallyDown
        checkbox.setAccessibilityRole(.checkBox)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.delegate = self
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.isHidden = true
        for view in [checkbox, icon, label, errorLabel] as [NSView] { addSubview(view) }
        textField = label
        imageView = icon
    }

    /// 可见条目身份由代理核对；更新文案时保留正在输入的选区和输入法组合文本。
    func configure(editing state: FileNameEditing) {
        suppressEndEditing = true
        defer { suppressEndEditing = false }
        if !editing {
            originalName = label.stringValue
        }
        editing = true
        if label.currentEditor() == nil { label.stringValue = state.name }
        let acceptsInput = !state.isSubmitting
        if label.isEnabled != acceptsInput { label.isEnabled = acceptsInput }
        if label.isEditable != acceptsInput { label.isEditable = acceptsInput }
        if label.isSelectable != acceptsInput { label.isSelectable = acceptsInput }
        label.isBezeled = true
        label.bezelStyle = .roundedBezel
        label.drawsBackground = true
        label.backgroundColor = .textBackgroundColor
        label.lineBreakMode = .byClipping
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.layer?.borderWidth = state.error == nil ? 0 : 1
        label.layer?.borderColor = NSColor.systemRed.cgColor
        errorLabel.stringValue = state.error ?? ""
        errorLabel.toolTip = state.error
        errorLabel.isHidden = state.error == nil
        label.setAccessibilityLabel("名称")
        label.setAccessibilityHelp(state.error)
        needsLayout = true
    }

    /// 表格提供单元格宽度，固定图标区后将剩余宽度全部交给名称。
    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 50)
        checkbox.frame = NSRect(x: 0, y: (bounds.height - 18) / 2, width: 18, height: 18)
        icon.frame = NSRect(x: 25, y: (bounds.height - 18) / 2, width: 18, height: 18)
        if errorLabel.isHidden {
            label.frame = NSRect(x: 50, y: (bounds.height - 22) / 2, width: width, height: 22)
        } else {
            label.frame = NSRect(x: 50, y: bounds.height - 25, width: width, height: 24)
            errorLabel.frame = NSRect(x: 50, y: 5, width: width, height: 14)
        }
        applyPendingFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsLayout = true }
    }

    /// 程序性刷新或销毁输入框不触发用户提交。
    func stopEditing() {
        guard editing else { return }
        suppressEndEditing = true
        editing = false
        pendingFocus = nil
        if label.currentEditor() != nil { window?.endEditing(for: label) }
        label.isEnabled = true
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.layer?.borderWidth = 0
        label.stringValue = originalName
        label.lineBreakMode = .byTruncatingMiddle
        errorLabel.isHidden = true
        needsLayout = true
        onNameChange = nil
        onNameSubmit = nil
        onNameCancel = nil
        suppressEndEditing = false
    }

    /// 焦点请求保留到视图已挂载且 field editor 建立，避免刷新过程中丢失首次编辑。
    func focusName(selection: NSRange?, selectAll: Bool) {
        guard editing, label.isEditable else { return }
        pendingFocus = (selection, selectAll)
        needsLayout = true
        layoutSubtreeIfNeeded()
        applyPendingFocus()
    }

    private func applyPendingFocus() {
        guard !isApplyingFocus, let request = pendingFocus, editing, label.isEditable,
              label.bounds.width > 0, let window else { return }
        isApplyingFocus = true
        defer { isApplyingFocus = false }
        if label.currentEditor() == nil {
            window.makeFirstResponder(label)
            if label.currentEditor() == nil { label.selectText(nil) }
        }
        guard let editor = label.currentEditor() as? NSTextView else { return }
        pendingFocus = nil
        if let selection = request.selection {
            let count = (editor.string as NSString).length
            let location = min(selection.location, count)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, count - location)))
        } else if request.selectAll { editor.selectAll(nil) }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard editing, !suppressEndEditing else { return }
        onNameChange?(label.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard editing, !suppressEndEditing, !isApplyingFocus else { return }
        onNameSubmit?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard editing else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onNameSubmit?()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onNameCancel?()
            return true
        }
        return false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggle() { onToggle?() }
}
