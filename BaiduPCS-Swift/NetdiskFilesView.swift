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
    @FocusState private var searchFocused: Bool
    @State private var showsNewFolder = false
    @State private var newFolderContext: DirectoryContext?
    @State private var folderName = ""
    @State private var creation: Creation?
    @State private var pendingDeletion: Deletion?
    @State private var deletion: Deletion?
    @State private var operationMessage: String?
    @State private var dropEntry: RemoteEntry?
    @State private var isDropTarget = false
    @ScaledMetric private var dateWidth = 110
    @ScaledMetric private var sizeWidth = 72

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
    private struct Deletion: Identifiable {
        let id = UUID()
        let context: DirectoryContext
        let targets: [(entry: RemoteEntry, parent: RemoteReference)]
    }
    private var isBusy: Bool { creation != nil || deletion != nil }
    private var sessionIdentity: ObjectIdentifier? {
        model.coordinator.netdisks[browser.provider].map(ObjectIdentifier.init)
    }
    private var accountName: String {
        model.coordinator.accountNames[browser.provider] ?? browser.provider.title
    }
    private var loadID: LoadID {
        .init(account: model.accountKey(for: browser.provider), session: sessionIdentity, generation: browser.generation)
    }
    private var canOperate: Bool {
        !isBusy && model.sheet == nil && browser.context.map(isCurrent) == true
    }

    var body: some View {
        VStack(spacing: 0) {
            navigation.padding(.horizontal).padding(.vertical, 10)
            if !pendingFiles.isEmpty { pendingUpload.padding(.horizontal).padding(.bottom, 10) }
            if let error = browser.errorMessage, browser.tree != nil {
                notice("更新失败：" + error)
            }
            if let operationMessage {
                HStack {
                    Text(operationMessage).font(.callout).textSelection(.enabled)
                    Spacer()
                    if !browser.query.isEmpty {
                        Button("清除筛选") { browser.query = "" }
                    }
                    Button { self.operationMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("关闭提示")
                }.padding(.horizontal).padding(.bottom, 10)
            }
            Divider()
            content
                .disabled(isBusy || browser.isLoading)
                .overlay {
                    if isDropTarget {
                        RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 2).padding(3).allowsHitTesting(false)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard canOperate, dropEntry == nil, let context = browser.context else { return false }
                    let files = urls.filter(\.isFileURL)
                    guard !files.isEmpty else { return false }
                    onUpload(context, files)
                    return true
                } isTargeted: {
                    isDropTarget = $0
                    if !$0 { dropEntry = nil }
                }
            Divider()
            HStack {
                if let tree = browser.tree { FileSelectionSummary(entries: tree.selectedEntries) }
                Spacer()
                if browser.isLoading { ProgressView().controlSize(.small) }
            }.padding(.horizontal).padding(.vertical, 8)
        }
        .navigationTitle(browser.provider.title)
        .navigationSubtitle(accountName)
        .toolbar { toolbar }
        .task(id: loadID) { await browser.load(model: model) }
        .task(id: creation?.id) { if let creation { await createFolder(creation) } }
        .task(id: deletion?.id) { if let deletion { await delete(deletion) } }
        .focusedSceneValue(\.focusTaskSearch, { searchFocused = true })
        .onChange(of: showsNewFolder || pendingDeletion != nil || isBusy) { _, presented in
            browser.isOperationPresented = presented
        }
        .onChange(of: browser.tree.map(ObjectIdentifier.init)) { _, _ in dropEntry = nil }
        .onDisappear {
            browser.clearSelection()
            browser.isOperationPresented = false
            dropEntry = nil
        }
        .alert("新建文件夹", isPresented: $showsNewFolder) {
            TextField("文件夹名称", text: $folderName)
            Button("取消", role: .cancel) { newFolderContext = nil }
            Button("新建") {
                guard let context = newFolderContext else { return }
                newFolderContext = nil
                guard isCurrent(context) else {
                    operationMessage = "网盘账号或登录状态已变化，请重新确认新建位置。"
                    return
                }
                creation = .init(context: context, name: folderName)
            }.disabled(!validFolderName(folderName))
        } message: { Text("在\(newFolderContext?.provider.title ?? browser.provider.title)的“\(newFolderContext?.pathDescription ?? "当前目录")”中新建文件夹。") }
        .alert("移到网盘回收站？", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { request in
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("移到回收站", role: .destructive) { pendingDeletion = nil; deletion = request }
        } message: { request in
            Text("\(request.context.provider.title) · \(accountName)\n\n\(request.targets.prefix(10).map { $0.entry.name }.joined(separator: "\n"))\n\n共 \(request.targets.count) 项。文件夹及其全部内容将移入网盘回收站，可能影响进行中的传输。任务记录和本地文件保留。")
        }
    }

    private var navigation: some View {
        HStack(spacing: 8) {
            Button {
                browser.navigate(to: Array(browser.trail.dropLast()))
            } label: { Image(systemName: "chevron.left") }
                .help("返回上一级").disabled(!browser.canGoUp || isBusy)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    Button("根目录") { browser.navigate(to: []) }
                    if browser.hasUnknownAncestors { Text("/ …").foregroundStyle(.secondary) }
                    ForEach(Array(browser.trail.enumerated()), id: \.element.id) { index, folder in
                        Text("/").foregroundStyle(.secondary)
                        Button(folder.name) { browser.navigate(to: Array(browser.trail.prefix(index + 1))) }
                    }
                }.buttonStyle(.plain).lineLimit(1)
            }.disabled(isBusy)
            Spacer(minLength: 0)
        }
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
            Button {
                if let context = browser.context { onUpload(context, []) }
            } label: { Label("上传", systemImage: "arrow.up.doc") }
                .disabled(!canOperate).help("上传到当前目录")
            Button {
                if let context = browser.context { onDownload(context, browser.selectedEntries) }
            } label: { Label("下载", systemImage: "arrow.down.to.line") }
                .disabled(!canOperate || browser.selectedEntries.isEmpty).help("下载勾选项目")
            Button {
                if let context = browser.context {
                    folderName = ""; newFolderContext = context; showsNewFolder = true
                }
            } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                .disabled(!canOperate).help("在当前目录新建文件夹")
            Button { prepareDeletion(browser.selectedEntries) } label: { Label("移到回收站", systemImage: "trash") }
                .disabled(!canOperate || browser.selectedEntries.isEmpty).help("将勾选项目移到网盘回收站")
            Button { browser.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                .disabled(isBusy || browser.isLoading).help("刷新当前目录")
        }
        ToolbarItem(placement: .primaryAction) {
            TextField("搜索当前目录", text: $browser.query)
                .textFieldStyle(.roundedBorder).frame(width: 150).focused($searchFocused)
                .accessibilityLabel("搜索当前目录")
        }
    }

    @ViewBuilder private var content: some View {
        if model.accountKey(for: browser.provider) == nil {
            ContentUnavailableView {
                Label("尚未登录\(browser.provider.title)", systemImage: "person.crop.circle")
            } description: { Text("登录后浏览和管理网盘文件。") } actions: {
                Button("登录") { model.presentLogin(for: browser.provider) }
            }
        } else if let tree = browser.tree {
            if tree.root.children?.isEmpty == true {
                ContentUnavailableView("此目录为空", systemImage: "folder")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if browser.rootNodes.isEmpty {
                ContentUnavailableView("没有匹配的文件", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(browser.rootNodes) { node in
                            FileTreeRow(node: node, tree: tree, isIncluded: false, badge: badge, columns: columns,
                                onUpload: { entry, files in
                                    if canOperate, let context = browser.context(for: entry) { onUpload(context, files) }
                                }, onDelete: { prepareDeletion(contextEntries($0)) },
                                orderedChildren: browser.orderedChildren, allowsExpansion: browser.query.isEmpty,
                                onOpen: { browser.enter($0) }, onDownload: { entry in
                                    if canOperate, let context = browser.context { onDownload(context, contextEntries(entry)) }
                                }, onCollapse: { tree.discardDescendantSelection(of: $0) },
                                onDropTarget: { entry, targeted in
                                    if targeted { dropEntry = entry }
                                    else if dropEntry?.reference == entry.reference { dropEntry = nil }
                                })
                        }
                    } header: { columnHeaders }
                }.id(ObjectIdentifier(tree))
            }
        } else if let error = browser.errorMessage {
            ContentUnavailableView {
                Label("无法读取网盘", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button("重试") { browser.refresh() }
                Button("重新登录") { model.presentLogin(for: browser.provider) }
            }
        } else { ProgressView("加载中").frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private var columnHeaders: some View {
        HStack(spacing: 8) {
            sortHeader(.name)
            Spacer()
            sortHeader(.modified).frame(width: dateWidth, alignment: .leading)
            sortHeader(.size).frame(width: sizeWidth, alignment: .trailing)
        }
    }

    /// 列标题直接切换同级条目的排序，再次点击当前列反转方向，不发起目录请求。
    private func sortHeader(_ sort: DirectoryBrowserState.Sort) -> some View {
        Button {
            if browser.sort == sort { browser.descending.toggle() }
            else { browser.sort = sort; browser.descending = false }
        } label: {
            HStack(spacing: 4) {
                Text(sort.title)
                if browser.sort == sort {
                    Image(systemName: browser.descending ? "chevron.down" : "chevron.up")
                        .font(.caption2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("按\(sort.title)排序")
        .accessibilityValue(browser.sort == sort ? (browser.descending ? "降序" : "升序") : "未排序")
        .help("点击按\(sort.title)排序，再次点击切换升降序")
        .disabled(isBusy || browser.isLoading)
    }

    @ViewBuilder private func badge(_ entry: RemoteEntry) -> some View {
        if browser.provider == .baidu, entry.isDirectory,
           RemotePath.normalized(entry.path) == RemotePath.normalized(model.settings.transferFolder(for: browser.provider)) {
            Text("转存目录").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: .rect(cornerRadius: 4)).fixedSize()
        }
    }

    private func columns(_ entry: RemoteEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.modifiedAt?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                .frame(width: dateWidth, alignment: .leading)
            Text(entry.isDirectory ? "—" : entry.size.byteCount)
                .frame(width: sizeWidth, alignment: .trailing)
        }.foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize(horizontal: true, vertical: false)
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

    private func validFolderName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    /// 只提交一次创建，服务端回执未确认时由用户刷新核对，不自动重发写请求。
    private func createFolder(_ request: Creation) async {
        defer { creation = nil }
        do {
            guard isCurrent(request.context) else { throw UploadDestinationError.otherAccount }
            let entry = try await model.createUploadDirectory(name: request.name, parent: request.context.reference,
                                                             account: request.context.account)
            guard isCurrent(request.context) else { throw UploadDestinationError.otherAccount }
            if browser.currentDirectory == request.context.reference { browser.revealCreated(entry) }
            operationMessage = browser.query.isEmpty ? "已创建“\(entry.name)”。" : "已创建“\(entry.name)”，若未显示请清除筛选查看。"
        } catch {
            if !Task.isCancelled { operationMessage = "新建结果未确认：\(error.localizedDescription)\n请刷新目录核对。" }
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
        operationMessage = "已确认移入回收站 \(confirmed) 项，未确认 \(request.targets.count - confirmed) 项。" +
            (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n"))
    }
}
