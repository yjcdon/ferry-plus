import AppKit
import FerryCore
import SwiftUI

/// 常驻文件页沿用下载页的展开勾选列表；传输确认交给主窗口，目录操作留在准确上下文中。
struct NetdiskFilesView: View {
    @Bindable var browser: DirectoryBrowserState
    let onUpload: (DirectoryContext, [URL]) -> Void
    let onDownload: (DirectoryContext, [RemoteEntry]) -> Void
    var allowsUpload = true
    var pendingFiles: [URL] = []
    var onConfirmPending: (DirectoryContext) -> Void = { _ in }
    var onCancelPending: () -> Void = {}
    @Environment(AppModel.self) private var model
    @State private var searchFocusRequest = 0
    @State private var contentWidth: CGFloat = 0
    @State private var creation: Creation?
    @State private var pendingDeletion: Deletion?
    @State private var deletion: Deletion?
    @State private var pendingRename: RenameTarget?
    @State private var renameName = ""
    @State private var renameError: String?
    @State private var renaming: RenameRequest?
    @State private var operationFeedback: OperationFeedback?
    @State private var isDropTarget = false

    private struct LoadID: Hashable {
        let account: AccountKey?
        let session: ObjectIdentifier?
        let generation: Int
    }
    private struct Creation: Identifiable {
        let id = UUID()
        let context: DirectoryContext
        let name: String
    }
    private struct OperationFeedback {
        let message: String
    }
    private struct Deletion: Identifiable {
        let id = UUID()
        let context: DirectoryContext
        let targets: [(entry: RemoteEntry, parent: RemoteReference)]
    }
    private struct RenameTarget: Identifiable {
        let id = UUID()
        let context: DirectoryContext
        let entry: RemoteEntry
        let parent: RemoteReference
        let wasSelected: Bool
    }
    private struct RenameRequest: Identifiable {
        let id = UUID()
        let target: RenameTarget
        let name: String
    }
    private var isBusy: Bool { creation != nil || deletion != nil || renaming != nil }
    private var sessionIdentity: ObjectIdentifier? {
        model.coordinator.netdisks[browser.provider].map(ObjectIdentifier.init)
    }
    private var loadID: LoadID {
        .init(account: model.accountKey(for: browser.provider), session: sessionIdentity, generation: browser.generation)
    }
    private var canOperate: Bool {
        !isBusy && pendingRename == nil && pendingDeletion == nil &&
        model.sheet == nil && browser.context.map(isCurrent) == true
    }
    private var canUpload: Bool { canOperate && allowsUpload }
    private var searchWidth: CGFloat { min(220, max(TaskSearchField.minimumWidth, contentWidth - 560)) }
    private var usesCompactToolbar: Bool { contentWidth < 700 }
    private var usesMinimalToolbar: Bool { contentWidth < 520 }

    var body: some View {
        VStack(spacing: 0) {
            navigation.padding(.horizontal).padding(.vertical, 10)
            if !pendingFiles.isEmpty { pendingUpload.padding(.horizontal).padding(.bottom, 10) }
            if let error = browser.errorMessage, browser.tree != nil {
                notice("更新失败：" + error)
            }
            if let operationFeedback {
                Banner(message: operationFeedback.message) {
                    if !browser.query.isEmpty { Button("清除筛选") { browser.query = "" } }
                    Button("关闭") { self.operationFeedback = nil }
                }
            }
            Divider()
            content
                .disabled(isBusy)
            Divider()
            HStack {
                if let tree = browser.tree { FileSelectionSummary(entries: tree.selectedEntries) }
                Spacer()
                if creation != nil {
                    ProgressView().controlSize(.small)
                    Text("创建中").foregroundStyle(.secondary)
                } else if browser.isLoading { ProgressView().controlSize(.small) }
            }.padding(.horizontal).workspaceFooter()
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { contentWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in contentWidth = width }
            }.allowsHitTesting(false)
        }
        .toolbar { toolbar }
        .task(id: loadID) { await browser.load(model: model) }
        .task(id: creation?.id) { if let creation { await createFolder(creation) } }
        .task(id: deletion?.id) { if let deletion { await delete(deletion) } }
        .task(id: renaming?.id) { if let renaming { await rename(renaming) } }
        .focusedSceneValue(\.focusTaskSearch, { searchFocusRequest += 1 })
        .onChange(of: loadID.account) { _, _ in operationFeedback = nil; pendingRename = nil }
        .onChange(of: loadID.session) { _, _ in operationFeedback = nil; pendingRename = nil }
        .onChange(of: pendingDeletion != nil || pendingRename != nil || isBusy) { _, presented in
            browser.isOperationPresented = presented
        }
        .onChange(of: browser.currentDirectory) { _, _ in pendingRename = nil }
        .onChange(of: browser.tree.map(ObjectIdentifier.init)) { _, _ in
            guard browser.tree != nil, !browser.isLoading, let target = pendingRename,
                  renaming == nil, browser.path(to: target.entry.reference) == nil else { return }
            operationFeedback = .init(message: renameError ?? "目录已更新，请重新选择项目。")
            pendingRename = nil
            renameError = nil
        }
        .onDisappear {
            pendingRename = nil
            browser.clearSelection()
            browser.isOperationPresented = false
            isDropTarget = false
            operationFeedback = nil
        }
        .sheet(item: $pendingDeletion) { request in
            VStack(spacing: 0) {
                HStack { Text("移到网盘回收站？").font(.headline); Spacer() }.padding()
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(request.targets.enumerated()), id: \.offset) { _, target in
                            HStack(spacing: 8) {
                                Image(systemName: target.entry.isDirectory ? "folder" : "doc")
                                    .foregroundStyle(target.entry.isDirectory ? Color.accentColor : Color.secondary)
                                Text(target.entry.name).lineLimit(1).truncationMode(.middle).help(target.entry.name)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding()
                }.frame(height: max(80, min(CGFloat(request.targets.count) * 26 + 32, 320)))
                Divider()
                HStack {
                    Spacer()
                    Button("取消", role: .cancel) { pendingDeletion = nil }.keyboardShortcut(.cancelAction)
                    Button("移到回收站", role: .destructive) {
                        pendingDeletion = nil
                        guard isCurrent(request.context) else {
                            operationFeedback = .init(message: "请重新选择账号和项目。")
                            return
                        }
                        deletion = request
                    }.keyboardShortcut(.defaultAction)
                }.padding()
            }.frame(width: deletionSheetWidth(request))
                .solidSheetSurface()
        }
    }

    /// 按最长文件名容纳删除清单，短内容保持紧凑，长名称在可用屏幕宽度内展示。
    private func deletionSheetWidth(_ request: Deletion) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let nameWidth = request.targets.map {
            ($0.entry.name as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let availableWidth = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.width ?? 900
        return min(max(320, ceil(nameWidth) + 64), min(720, availableWidth * 0.8))
    }

    private var navigation: some View {
        HStack(spacing: 8) {
            Button {
                browser.navigate(to: Array(browser.trail.dropLast()))
            } label: { Image(systemName: "chevron.left") }
                .help("返回上一级").disabled(!browser.canGoUp || isBusy)
            ViewThatFits(in: .horizontal) {
                breadcrumb(compact: false).fixedSize(horizontal: true, vertical: false)
                breadcrumb(compact: true)
            }.disabled(isBusy)
            Spacer(minLength: 0)
        }
    }

    /// 完整路径优先展示；空间不足时才将中间目录收入菜单，保留根目录和当前位置。
    private func breadcrumb(compact: Bool) -> some View {
        HStack(spacing: 6) {
            Button("根目录") { browser.navigate(to: []) }.fixedSize()
            if browser.hasUnknownAncestors { Text("/ …").foregroundStyle(.secondary) }
            if compact, browser.trail.count > 1 {
                Text("/").foregroundStyle(.secondary)
                Menu {
                    ForEach(Array(browser.trail.dropLast().enumerated()), id: \.element.id) { index, folder in
                        Button(folder.name) { browser.navigate(to: Array(browser.trail.prefix(index + 1))) }
                    }
                } label: { Text("…") }
                    .menuStyle(.borderlessButton).fixedSize().help("上级目录")
            }
            ForEach(Array(browser.trail.enumerated()), id: \.element.id) { index, folder in
                if !compact || index == browser.trail.count - 1 {
                    Text("/").foregroundStyle(.secondary)
                    Button(folder.name) { browser.navigate(to: Array(browser.trail.prefix(index + 1))) }
                        .truncationMode(.middle)
                }
            }
        }.buttonStyle(.plain).lineLimit(1)
    }

    private var pendingUpload: some View {
        HStack {
            Text("待上传 \(pendingFiles.count) 项，请选择目标目录后确认。")
            Spacer()
            Button("取消", action: onCancelPending)
            Button("上传到当前目录") {
                if let context = browser.context { onConfirmPending(context) }
            }.disabled(!canUpload)
        }.font(.callout)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if #available(macOS 26.0, *), !usesCompactToolbar {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 12) {
                if usesMinimalToolbar {
                    Menu("操作") {
                        transferActions
                        Divider()
                        directoryActions
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("上传、下载和目录操作")
                    .accessibilityLabel("文件操作")
                } else {
                    transferActions
                    if usesCompactToolbar {
                        Menu("操作") { directoryActions }
                            .menuStyle(.borderlessButton).fixedSize()
                            .help("移到回收站和刷新")
                            .accessibilityLabel("文件操作")
                    } else {
                        directoryActions
                    }
                }
            }
            .toolbarControlSurface()
        }
        .solidToolbarBackground()
        if #available(macOS 26.0, *), !usesCompactToolbar {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(id: "files.search", placement: .primaryAction) {
            TaskSearchField(text: $browser.query, focusRequest: searchFocusRequest, placeholder: "搜索当前目录")
                .frame(width: searchWidth)
                .toolbarControlSurface()
        }
        .solidToolbarBackground()
    }

    /// 上传和下载在常规工具栏与最窄窗口菜单间共用当前目录、选择及启用条件。
    @ViewBuilder private var transferActions: some View {
        Button {
            if let context = browser.context { onUpload(context, []) }
        } label: { Label("上传", systemImage: "icloud.and.arrow.up") }
            .disabled(!canUpload).help("上传到当前目录")
            .accessibilityLabel("上传")
        Button {
            if let context = browser.context { onDownload(context, browser.selectedEntries) }
        } label: { Label("下载", systemImage: "arrow.down") }
            .disabled(!canOperate || browser.selectedEntries.isEmpty).help("下载选中项目")
            .accessibilityLabel("下载")
    }

    /// 次要目录操作在宽窗平铺、窄窗收入菜单，共用同一目标和启用条件。
    @ViewBuilder private var directoryActions: some View {
        Button { prepareDeletion(browser.selectedEntries) } label: { Label("移到回收站", systemImage: "trash") }
            .disabled(!canOperate || browser.selectedEntries.isEmpty).help("将选中项目移到网盘回收站")
            .accessibilityLabel("移到回收站")
        Button { browser.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
            .disabled(isBusy || browser.isLoading).help("刷新当前目录")
            .accessibilityLabel("刷新")
    }

    @ViewBuilder private var content: some View {
        if model.accountKey(for: browser.provider) == nil {
            ContentUnavailableView {
                Label("登录\(browser.provider.title)", systemImage: "person.crop.circle")
            } description: { Text("登录后浏览和管理网盘文件。") } actions: {
                Button("登录") { model.presentLogin(for: browser.provider) }
            }
        } else if let tree = browser.tree {
            if tree.root.children?.isEmpty == true {
                emptyContent("此目录为空", systemImage: "folder")
            } else if browser.rootNodes.isEmpty {
                emptyContent("试试其他关键词", systemImage: "magnifyingglass")
            } else {
                NetdiskOutlineView(browser: browser, tree: tree,
                    transferFolder: model.settings.transferFolder(for: browser.provider),
                    allowsUpload: canUpload,
                    onUpload: { entry, files in
                        guard canUpload else { return false }
                        let context: DirectoryContext?
                        if let entry { context = browser.context(for: entry) }
                        else { context = browser.context }
                        guard let context else { return false }
                        onUpload(context, files)
                        return true
                    }, onDownload: { entry in
                        if canOperate, let context = browser.context { onDownload(context, contextEntries(entry)) }
                    }, onRename: prepareRename, onDelete: { prepareDeletion(contextEntries($0)) },
                    onNewFolder: newFolderAction, nameEditing: nameEditing)
                    .id(ObjectIdentifier(tree))
            }
        } else if let error = browser.errorMessage {
            ContentUnavailableView {
                Label("网盘读取失败", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button("重试") { browser.refresh() }
                Button("重新登录") { model.presentLogin(for: browser.provider) }
            }
        } else { ProgressView("加载中").frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    /// 空内容提供当前目录投放；有列表时由原生表格管理拖放和表头事件。
    private func emptyContent(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .contextMenu {
                Button("新建文件夹", action: prepareNewFolder).disabled(!canOperate)
            }
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 2).padding(3).allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard canUpload, let context = browser.context else { return false }
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                onUpload(context, files)
                return true
            } isTargeted: { isDropTarget = $0 }
    }

    private var newFolderAction: (() -> Void)? {
        guard canOperate else { return nil }
        return { prepareNewFolder() }
    }

    /// 在当前目录创建默认名称，收到准确回执后立即在列表中编辑名称。
    private func prepareNewFolder() {
        guard canOperate, let context = browser.context,
              let nodes = browser.tree?.root.children else { return }
        let names = Set(nodes.compactMap { $0.entry?.name })
        let base = "未命名文件夹"
        var name = base
        var suffix = 2
        while names.contains(name) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        operationFeedback = nil
        browser.query = ""
        creation = .init(context: context, name: name)
    }

    private var nameEditing: FileNameEditing? {
        guard let target = pendingRename else { return nil }
        return .init(reference: target.entry.reference, name: renameName, error: renameError,
                     isSubmitting: renaming != nil,
                     onChange: { renameName = $0; renameError = nil },
                     onSubmit: { submitRename(target) },
                     onCancel: { if renaming == nil { pendingRename = nil; renameError = nil } })
    }

    private func notice(_ message: String) -> some View {
        Banner(message: message) {
            Button("重试") { browser.refresh() }.disabled(browser.isLoading || isBusy)
        }
    }

    private func isCurrent(_ context: DirectoryContext) -> Bool {
        model.accountKey(for: context.provider) == context.account &&
        model.coordinator.netdisks[context.provider].map(ObjectIdentifier.init) == context.session
    }

    private func contextEntries(_ entry: RemoteEntry) -> [RemoteEntry] {
        if browser.tree?.selection.contains(entry.id) == true { return browser.selectedEntries }
        return [entry]
    }

    /// 各目标父目录来自同一树中的真实路径，父目录已经包含的子项只提交一次。
    private func prepareDeletion(_ entries: [RemoteEntry]) {
        guard canOperate, let context = browser.context, !entries.isEmpty else { return }
        let references = Set(entries.map(\.reference))
        var targets: [(entry: RemoteEntry, parent: RemoteReference)] = []
        for entry in entries {
            guard let path = browser.path(to: entry.reference) else { return }
            if path.dropLast().contains(where: { references.contains($0.reference) }) { continue }
            targets.append((entry, path.dropLast().last?.reference ?? context.reference))
        }
        pendingDeletion = .init(context: context, targets: targets)
    }

    /// 提交时校验名称，错误留在行内，输入及准确目标保持可恢复。
    private func submitRename(_ target: RenameTarget) {
        guard renaming == nil else { return }
        if let message = NetdiskRenameError.validationMessage(renameName, provider: target.context.provider) {
            renameError = message
            return
        }
        guard renameName != target.entry.name else { pendingRename = nil; return }
        guard isCurrent(target.context) else {
            renameError = "请重新选择账号和项目。"
            return
        }
        renameError = nil
        renaming = .init(target: target, name: renameName)
    }

    /// 右键条目独立改名，使用树中的准确父目录，不扩展为多项操作。
    private func prepareRename(_ entry: RemoteEntry) {
        guard canOperate, let context = browser.context, let path = browser.path(to: entry.reference) else { return }
        renameName = entry.name
        renameError = nil
        pendingRename = .init(context: context, entry: entry, parent: path.dropLast().last?.reference ?? context.reference,
                              wasSelected: browser.tree?.selection.contains(entry.id) == true)
    }

    /// 会话一致时提交一次，成功按回执定位新名称；失败刷新当前目录供用户核对。
    private func rename(_ request: RenameRequest) async {
        defer { renaming = nil }
        do {
            guard isCurrent(request.target.context) else { throw UploadDestinationError.otherAccount }
            let disk = try model.netdisk(for: request.target.context.provider)
            let renamed = try await disk.rename(entry: request.target.entry, parent: request.target.parent,
                                                newName: request.name, account: request.target.context.account)
            try Task.checkCancellation()
            guard isCurrent(request.target.context) else { throw UploadDestinationError.otherAccount }
            pendingRename = nil
            if browser.currentDirectory == request.target.context.reference {
                browser.reveal(renamed, select: request.target.wasSelected)
            }
            else { browser.refresh() }
            operationFeedback = nil
        } catch {
            if !Task.isCancelled {
                renameError = isCurrent(request.target.context) ? error.localizedDescription : "请重新选择账号和项目。"
                if isCurrent(request.target.context) { browser.refresh() }
            }
        }
    }

    /// 从已加载目录选择默认名；创建只提交一次，按准确回执插入列表后编辑。
    private func createFolder(_ request: Creation) async {
        defer { creation = nil }
        do {
            guard isCurrent(request.context) else { throw UploadDestinationError.otherAccount }
            let entry = try await model.createUploadDirectory(name: request.name, parent: request.context.reference,
                                                             account: request.context.account)
            try Task.checkCancellation()
            guard isCurrent(request.context) else { throw UploadDestinationError.otherAccount }
            if browser.currentDirectory == request.context.reference {
                renameName = entry.name
                renameError = nil
                pendingRename = .init(context: request.context, entry: entry,
                                      parent: request.context.reference, wasSelected: true)
                browser.insertCreated(entry)
            }
        } catch {
            if !Task.isCancelled {
                operationFeedback = .init(message: isCurrent(request.context) ? error.localizedDescription : "请重新选择账号和新建位置。")
            }
        }
    }

    /// 部分成功如实报告，换号后停止尚未发送的项目，不改变任何传输任务或本地文件。
    private func delete(_ request: Deletion) async {
        var confirmed = 0
        var failures: [String] = []
        defer {
            deletion = nil
            if isCurrent(request.context) { browser.refresh() }
        }
        for target in request.targets {
            do {
                try Task.checkCancellation()
                guard isCurrent(request.context) else { throw UploadDestinationError.otherAccount }
                let disk = try model.netdisk(for: request.context.provider)
                try await disk.moveToTrash(entry: target.entry, parent: target.parent, account: request.context.account)
                confirmed += 1
            } catch {
                if Task.isCancelled || error is CancellationError { break }
                failures.append("\(target.entry.name)：\(error.localizedDescription)")
                if !isCurrent(request.context) { break }
            }
        }
        guard isCurrent(request.context), !Task.isCancelled else { return }
        let unconfirmed = request.targets.count - confirmed
        guard unconfirmed > 0 else { operationFeedback = nil; return }
        let message = "已移入回收站 \(confirmed) 项。" +
            "\n\(unconfirmed) 项待处理。" +
            (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n"))
        operationFeedback = .init(message: message)
    }
}
