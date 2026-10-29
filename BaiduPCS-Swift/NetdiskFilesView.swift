import AppKit
import FerryCore
import SwiftUI

/// 常驻文件页沿用下载页的展开勾选列表；传输确认交给主窗口，目录操作留在准确上下文中。
struct NetdiskFilesView: View {
    @Bindable var browser: DirectoryBrowserState
    let onUpload: (DirectoryContext, [URL]) -> Void
    let onDownload: (DirectoryContext, [RemoteEntry]) -> Void
    var pendingFiles: [URL] = []
    var onConfirmPending: (DirectoryContext) -> Void = { _ in }
    var onCancelPending: () -> Void = {}
    @Environment(AppModel.self) private var model
    @State private var searchFocusRequest = 0
    @State private var contentWidth: CGFloat = 0
    @State private var pendingNewFolder: NewFolderTarget?
    @State private var folderName = ""
    @State private var folderError: String?
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
    private struct NewFolderTarget: Identifiable {
        let id = UUID()
        let context: DirectoryContext
    }
    private struct OperationFeedback: Identifiable {
        let id = UUID()
        let message: String
        let isError: Bool
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
        !isBusy && pendingNewFolder == nil && pendingRename == nil && pendingDeletion == nil &&
        model.sheet == nil && browser.context.map(isCurrent) == true
    }
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
                HStack {
                    if operationFeedback.isError {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    Text(operationFeedback.message).font(.callout).textSelection(.enabled)
                    Spacer()
                    if !browser.query.isEmpty {
                        Button("清除筛选") { browser.query = "" }
                    }
                    Button { self.operationFeedback = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("关闭提示")
                }.padding(.horizontal).padding(.bottom, 10)
            }
            Divider()
            content
                .disabled(isBusy)
            Divider()
            HStack {
                if let tree = browser.tree { FileSelectionSummary(entries: tree.selectedEntries) }
                Spacer()
                if browser.isLoading { ProgressView().controlSize(.small) }
            }.padding(.horizontal).padding(.vertical, 8)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { contentWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in contentWidth = width }
            }.allowsHitTesting(false)
        }
        .navigationTitle(browser.provider.title)
        .toolbar { toolbar }
        .task(id: loadID) { await browser.load(model: model) }
        .task(id: operationFeedback?.id) {
            guard let feedback = operationFeedback, !feedback.isError else { return }
            do {
                try await Task.sleep(for: .seconds(10))
                if operationFeedback?.id == feedback.id { operationFeedback = nil }
            } catch is CancellationError {
                // 新提示或页面关闭会取消旧提示的倒计时。
            } catch { assertionFailure("Unexpected sleep error: \(error)") }
        }
        .task(id: creation?.id) { if let creation { await createFolder(creation) } }
        .task(id: deletion?.id) { if let deletion { await delete(deletion) } }
        .task(id: renaming?.id) { if let renaming { await rename(renaming) } }
        .focusedSceneValue(\.focusTaskSearch, { searchFocusRequest += 1 })
        .onChange(of: loadID.account) { _, _ in operationFeedback = nil }
        .onChange(of: loadID.session) { _, _ in operationFeedback = nil }
        .onChange(of: pendingNewFolder != nil || pendingDeletion != nil || pendingRename != nil || isBusy) { _, presented in
            browser.isOperationPresented = presented
        }
        .onDisappear {
            browser.clearSelection()
            browser.isOperationPresented = false
            isDropTarget = false
            operationFeedback = nil
        }
        .sheet(item: $pendingNewFolder) { target in
            NameInputSheet(title: "新建文件夹", prompt: "文件夹名称", submitTitle: "新建",
                           name: $folderName, error: $folderError, isSubmitting: creation != nil,
                           destination: target.context.pathDescription,
                           onCancel: { pendingNewFolder = nil }, onSubmit: { submitNewFolder(target) })
        }
        .sheet(item: $pendingRename, content: renameSheet)
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
                                Text(target.entry.name).lineLimit(1).truncationMode(.middle)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding()
                }.frame(minHeight: 60, idealHeight: min(CGFloat(request.targets.count) * 28 + 32, 180), maxHeight: 180)
                Divider()
                HStack {
                    Spacer()
                    Button("取消", role: .cancel) { pendingDeletion = nil }.keyboardShortcut(.cancelAction)
                    Button("移到回收站", role: .destructive) {
                        pendingDeletion = nil
                        guard isCurrent(request.context) else {
                            operationFeedback = .init(message: "请重新选择账号和项目。", isError: true)
                            return
                        }
                        deletion = request
                    }.keyboardShortcut(.defaultAction)
                }.padding()
            }.frame(minWidth: 600, idealWidth: 660)
                .solidSheetSurface()
        }
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
            }.disabled(!canOperate)
        }.font(.callout)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
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
                        .help("新建文件夹、移到回收站和刷新")
                        .accessibilityLabel("文件操作")
                } else {
                    directoryActions
                }
            }
        }
        .solidToolbarBackground()
        if #available(macOS 26.0, *), !usesCompactToolbar {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(id: "files.search", placement: .primaryAction) {
            TaskSearchField(text: $browser.query, focusRequest: searchFocusRequest, placeholder: "搜索当前目录")
                .frame(width: searchWidth)
        }
        .solidToolbarBackground()
    }

    /// 上传和下载在常规工具栏与最窄窗口菜单间共用当前目录、选择及启用条件。
    @ViewBuilder private var transferActions: some View {
        Button {
            if let context = browser.context { onUpload(context, []) }
        } label: { Label("上传", systemImage: "arrow.up.doc") }
            .disabled(!canOperate).help("上传到当前目录")
        Button {
            if let context = browser.context { onDownload(context, browser.selectedEntries) }
        } label: { Label("下载", systemImage: "arrow.down.to.line") }
            .disabled(!canOperate || browser.selectedEntries.isEmpty).help("下载勾选项目")
    }

    /// 次要目录操作在宽窗平铺、窄窗收入菜单，共用同一目标和启用条件。
    @ViewBuilder private var directoryActions: some View {
        Button {
            if let context = browser.context {
                folderName = ""; folderError = nil
                pendingNewFolder = .init(context: context)
            }
        } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
            .disabled(!canOperate).help("在当前目录新建文件夹")
        Button { prepareDeletion(browser.selectedEntries) } label: { Label("移到回收站", systemImage: "trash") }
            .disabled(!canOperate || browser.selectedEntries.isEmpty).help("将勾选项目移到网盘回收站")
        Button { browser.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
            .disabled(isBusy || browser.isLoading).help("刷新当前目录")
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
                    allowsUpload: canOperate,
                    onUpload: { entry, files in
                        guard canOperate else { return false }
                        let context = entry.flatMap { browser.context(for: $0) } ?? browser.context
                        guard let context else { return false }
                        onUpload(context, files)
                        return true
                    }, onDownload: { entry in
                        if canOperate, let context = browser.context { onDownload(context, contextEntries(entry)) }
                    }, onRename: prepareRename, onDelete: { prepareDeletion(contextEntries($0)) })
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
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 2).padding(3).allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard canOperate, let context = browser.context else { return false }
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                onUpload(context, files)
                return true
            } isTargeted: { isDropTarget = $0 }
    }

    private func notice(_ message: String) -> some View {
        HStack { Label(message, systemImage: "exclamationmark.triangle").font(.callout); Spacer() }
            .padding(.horizontal).padding(.bottom, 10)
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

    /// 校验失败保留名称和弹窗，红框与简短提示直接标记需要修改的输入。
    private func renameSheet(_ target: RenameTarget) -> some View {
        NameInputSheet(title: "重命名", prompt: "名称", submitTitle: "确定",
                       name: $renameName, error: $renameError, isSubmitting: renaming != nil,
                       onCancel: { pendingRename = nil }, onSubmit: { submitRename(target) })
    }

    /// 新建和改名采用同一名称约束，提交失败时在原面板保留输入与提示。
    private func submitNewFolder(_ target: NewFolderTarget) {
        if let message = NetdiskRenameError.validationMessage(folderName, provider: target.context.provider) {
            folderError = message
            return
        }
        guard isCurrent(target.context) else {
            folderError = "请重新选择账号和新建位置。"
            return
        }
        folderError = nil
        creation = .init(context: target.context, name: folderName)
    }

    /// 仅在点击确定时校验名称，不用禁用按钮隐藏无效输入的原因。
    private func submitRename(_ target: RenameTarget) {
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
            operationFeedback = .init(message: "已重命名为【\(request.name)】。", isError: false)
        } catch {
            if !Task.isCancelled {
                renameError = isCurrent(request.target.context) ? error.localizedDescription : "请重新选择账号和项目。"
                if isCurrent(request.target.context) { browser.refresh() }
            }
        }
    }

    /// 只提交一次创建，服务端回执未确认时由用户刷新核对，不自动重发写请求。
    private func createFolder(_ request: Creation) async {
        defer { creation = nil }
        do {
            guard isCurrent(request.context) else { throw UploadDestinationError.otherAccount }
            let entry = try await model.createUploadDirectory(name: request.name, parent: request.context.reference,
                                                             account: request.context.account)
            try Task.checkCancellation()
            guard isCurrent(request.context) else { throw UploadDestinationError.otherAccount }
            if browser.currentDirectory == request.context.reference { browser.reveal(entry, select: true) }
            pendingNewFolder = nil
            operationFeedback = .init(message: "已创建【\(entry.name)】。", isError: false)
        } catch {
            if !Task.isCancelled {
                folderError = isCurrent(request.context) ? error.localizedDescription : "请重新选择账号和新建位置。"
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
        let message = "已移入回收站 \(confirmed) 项。" +
            (unconfirmed > 0 ? "\n\(unconfirmed) 项待处理。" : "") +
            (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n"))
        operationFeedback = .init(message: message, isError: unconfirmed > 0)
    }
}

/// 名称编辑保持同一输入、错误和提交布局，异步操作期间固定当前面板。
private struct NameInputSheet: View {
    let title: String
    let prompt: String
    let submitTitle: String
    @Binding var name: String
    @Binding var error: String?
    let isSubmitting: Bool
    var destination: String? = nil
    let onCancel: () -> Void
    let onSubmit: () -> Void
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if let destination {
                Text("新建到【\(destination)】").font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            TextField(prompt, text: $name)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(error == nil ? Color.secondary.opacity(0.4) : Color.red,
                                lineWidth: error == nil ? 1 : 2)
                }
                .accessibilityLabel(prompt)
                .accessibilityHint(error ?? "")
                .focused($isNameFocused)
                .disabled(isSubmitting)
                .onChange(of: name) { _, _ in error = nil }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                if isSubmitting { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction).disabled(isSubmitting)
                Button(submitTitle, action: onSubmit)
                    .keyboardShortcut(.defaultAction).disabled(isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 480)
        .solidSheetSurface()
        .interactiveDismissDisabled(isSubmitting)
        .onAppear { isNameFocused = true }
    }
}
