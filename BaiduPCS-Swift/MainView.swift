import AppKit
import FerryCore
import SwiftUI

/// 方向、网盘、分类和搜索共同决定可见范围；所有交互共享带方向的选择及父页命令入口。
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var workspace = WorkspaceState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var uploadConfirmation: UploadConfirmationTarget?
    @State private var downloadConfirmation: DownloadConfirmationTarget?
    @State private var uploadPhases: [UUID: UploadPhase] = [:]
    @State private var hasUploadBaseline = false
    @State private var category: JobCategory? = .all
    @State private var providerFilter: Provider?
    @State private var direction: TransferDirectionFilter = .all
    @State private var selection: Set<TransferTaskID> = []
    @SceneStorage("isInspectorPresented") private var isInspectorPresented = false
    @SceneStorage("transferInspectorWidth") private var inspectorWidth: Double = 320
    @State private var workspaceWidth: CGFloat = 960
    @State private var detailWidth: CGFloat = 760
    @State private var searchText = ""
    @State private var searchFocusRequest = 0
    @State private var pendingRemoval: PendingTransferRemoval?
    @State private var uploadCommand: UploadCommand?
    @State private var operationError: String?
    @State private var revealedUploadID: UUID?
    @State private var downloadRemoval = DownloadRemovalFlow()

    private struct DownloadRemovalRequest: Identifiable {
        let job: Job
        let removal: JobRemoval
        let cleanup: Bool?
        var id: UUID { job.id }
    }
    private struct DownloadRemovalFlow {
        var queue: [DownloadRemovalRequest] = []
        var errors: [String] = []
        var isProcessing = false
        var isIdle: Bool { !isProcessing }
    }

    private struct UploadCommand: Identifiable {
        let id = UUID()
        let action: UploadAction
        let jobs: [UploadJob]
    }
    private var currentCategory: JobCategory { category ?? .all }
    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// 侧边栏各分类的数字也应用方向、来源和搜索，但不预先套用当前分类。
    private var filteredDownloads: [Job] {
        guard direction != .upload else { return [] }
        return model.coordinator.jobs.filter { job in
            (providerFilter == nil || job.provider == providerFilter) &&
            (query.isEmpty || job.matches(query) || job.accountName?.localizedCaseInsensitiveContains(query) == true || job.provider.title.localizedCaseInsensitiveContains(query))
        }
    }
    private var filteredUploads: [UploadJob] {
        guard direction != .download else { return [] }
        return model.uploadJobs.filter { job in
            (providerFilter == nil || job.account.provider == providerFilter) &&
            (query.isEmpty || job.title.localizedCaseInsensitiveContains(query) || job.accountName.localizedCaseInsensitiveContains(query) || job.account.provider.title.localizedCaseInsensitiveContains(query))
        }
    }
    private var visibleItems: [TransferListItem] {
        visibleItems(downloads: filteredDownloads, uploads: filteredUploads)
    }

    /// 同次渲染复用侧栏的过滤结果；命令入口仍通过计算属性重新取当前范围。
    private func visibleItems(downloads: [Job], uploads: [UploadJob]) -> [TransferListItem] {
        let downloads = downloads.filter(currentCategory.contains).map(TransferListItem.download)
        let uploads = uploads.filter(currentCategory.contains).map(TransferListItem.upload)
        return (downloads + uploads).sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            if $0.id.direction != $1.id.direction { return $0.id.direction.rawValue < $1.id.direction.rawValue }
            return $0.id.id.uuidString < $1.id.id.uuidString
        }
    }
    private func transferScope(items: [TransferListItem]) -> TransferSelection {
        return .init(selectedItems: items.filter { selection.contains($0.id) }, visibleItems: items,
            providerFilter: providerFilter, isBusy: uploadCommand != nil,
            onAction: perform, onRemove: requestRemoval, onInspect: inspect)
    }

    var body: some View {
        let downloads = filteredDownloads
        let uploads = filteredUploads
        let items = visibleItems(downloads: downloads, uploads: uploads)
        let scope = transferScope(items: items)
        let layout = workspaceLayout(downloads: downloads, uploads: uploads, items: items, scope: scope)
            .focusedSceneValue(\.selectWorkspaceItems, selectWorkspaceItemsAction)
        let events = workspaceEvents(layout, items: items, scope: scope)
        transferDialogs(events)
    }

    private func workspaceLayout(downloads: [Job], uploads: [UploadJob], items: [TransferListItem],
                                 scope: TransferSelection) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(page: $workspace.page, providerFilter: providerFilter,
                        onShowAll: {
                            providerFilter = nil
                            workspace.page = .transfers(currentCategory)
                        }, jobs: downloads, uploadJobs: uploads)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
        } detail: {
            if workspace.isFiles {
                filesContent
            } else {
                // 显式宽度与独立拖动条避免 inspector 和原生分栏相互反馈尺寸。
                HStack(spacing: 0) {
                    transferContent(items: items, scope: scope)
                    if showsInspector {
                        WidthResizeHandle(width: effectiveInspectorWidth, minimum: 280,
                                          maximum: maximumInspectorWidth, fillsHeight: true)
                            .frame(width: 8)
                            .frame(maxHeight: .infinity)
                        TransferInspector(scope: scope, onDownloadRemove: requestDownloadRemoval)
                            .frame(width: effectiveInspectorWidth.wrappedValue)
                            .frame(maxHeight: .infinity)
                    }
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in detailWidth = width }
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onChange(of: geometry.size.width, initial: true) { _, width in workspaceWidth = width }
            }
        }
    }

    /// 空间不足时收起详情，用户的展开与宽度偏好随窗口恢复。
    private var showsInspector: Bool { isInspectorPresented && detailWidth >= 640 }

    private var maximumInspectorWidth: CGFloat { min(workspaceWidth / 2, detailWidth - 328) }

    /// 显式打开窄窗详情时让侧栏腾出空间；自动收起只影响实际展示。
    private var inspectorPresentation: Binding<Bool> {
        Binding(get: { showsInspector }, set: { presented in
            isInspectorPresented = presented
            if presented && detailWidth < 640 { columnVisibility = .detailOnly }
        })
    }

    /// 详情至多半窗，并为主列表保留可用空间；拖动只保存用户偏好宽度。
    private var effectiveInspectorWidth: Binding<CGFloat> {
        Binding(
            get: { min(max(CGFloat(inspectorWidth), 280), max(280, maximumInspectorWidth)) },
            set: { inspectorWidth = Double($0) }
        )
    }

    private func workspaceEvents<Content: View>(_ content: Content, items: [TransferListItem],
                                               scope: TransferSelection) -> some View {
        content
        #if DEBUG
        .task { await showDemoSelection() }
        #endif
        .onChange(of: model.workspaceRequest?.id, initial: true) { _, _ in
            consumeWorkspaceRequest()
        }
        .onChange(of: hasWorkspacePresentation, initial: true) { _, presented in
            model.isWorkspaceDialogPresented = presented
        }
        .onDisappear { model.isWorkspaceDialogPresented = false }
        .onChange(of: workspace.browser.context != nil) { _, ready in
            if ready { presentRequestedUpload() }
        }
        .onChange(of: canPresentConfirmation) { _, available in
            if available {
                consumeWorkspaceRequest()
                presentRequestedUpload()
            }
        }
        .onChange(of: model.sheet) { _, sheet in
            if sheet == nil { consumeWorkspaceRequest() }
        }
        .onChange(of: workspace.page, initial: true) { old, page in
            if old != page, let provider = old?.provider { workspace.browser(for: provider).clearSelection() }
            if let provider = page?.provider { providerFilter = provider }
            if case .transfers(let selected) = page { category = selected }
        }
        .focusedSceneValue(\.transferSelection, workspace.isFiles ? nil : scope)
        .focusedSceneValue(\.transferInspectorPresented, workspace.isFiles ? nil : inspectorPresentation)
        .focusedSceneValue(\.workspaceIsFiles, workspace.isFiles)
        .onChange(of: items.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .onChange(of: model.lastAddedJobID) { _, id in
            guard let id, let job = model.coordinator.jobs.first(where: { $0.id == id }) else { return }
            if workspace.isFiles { workspace.lastAddedTransfer = .init(direction: .download, id: id) }
            else { reveal(.download(job)) }
        }
        .onChange(of: model.lastAddedUploadID) { revealNewUpload() }
        .onChange(of: model.uploadJobs.map(\.id)) { revealNewUpload() }
        .onChange(of: model.uploadJobs.map { UploadPhaseSnapshot(id: $0.id, account: $0.account, phase: $0.phase) }, initial: true) { _, snapshots in
            updateDirectoryInvalidation(snapshots)
        }
        .sheet(item: $uploadConfirmation, onDismiss: consumeWorkspaceRequest) { target in
            UploadConfirmationView(target: target) { workspace.pendingFiles = [] }
        }
        .sheet(item: $downloadConfirmation, onDismiss: consumeWorkspaceRequest) { target in
            DownloadConfirmationView(target: target) {}
        }
        .task(id: uploadCommand?.id) {
            guard let uploadCommand else { return }
            await performUpload(uploadCommand)
        }
    }

    private func transferDialogs<Content: View>(_ content: Content) -> some View {
        content
        .confirmationDialog(pendingRemoval?.title ?? "", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { pending in
            Button(pending.removal == .trashingFiles ? "移到废纸篓" : "移除记录", role: .destructive) {
                pendingRemoval = nil
                remove(pending)
            }
        } message: { pending in Text(pending.message) }
        .alert("传输操作提示", isPresented: Binding(
            get: { operationError != nil }, set: { if !$0 { operationError = nil } }
        )) { Button("好") { operationError = nil } } message: { Text(operationError ?? "") }
        .alert("请在 Finder 中处理剩余文件", isPresented: Binding(
            get: { !model.untrashedItems.isEmpty }, set: { if !$0 { model.untrashedItems = [] } }
        ), presenting: model.untrashedItems) { items in
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting(items) }
            Button("好", role: .cancel) {}
        } message: { items in Text("\(items.count) 项仍在原来的位置，可以在 Finder 中手动删除。") }
    }

    private var selectWorkspaceItemsAction: (() -> Void)? {
        guard canPresentConfirmation, uploadCommand == nil else { return nil }
        if workspace.isFiles {
            guard workspace.browser.context != nil else { return nil }
            return { workspace.browser.selectAll() }
        }
        return { selection = Set(visibleItems.map(\.id)) }
    }

    private var canPresentConfirmation: Bool {
        model.sheet == nil && !hasWorkspacePresentation && !model.isConfirmingMenuLogOut && model.untrashedItems.isEmpty
    }

    /// 只由主窗口实际流程推导占用；不反读反馈给 AppModel 的标记，避免关闭后自锁。
    private var hasWorkspacePresentation: Bool {
        uploadConfirmation != nil || downloadConfirmation != nil ||
        workspace.browser.isOperationPresented || pendingRemoval != nil || !downloadRemoval.isIdle || operationError != nil
    }

    private var filesContent: some View {
        VStack(spacing: 0) {
            if let added = workspace.lastAddedTransfer {
                HStack {
                    Text("已加入传输")
                    Spacer()
                    Button("查看传输") {
                        switch added.direction {
                        case .download:
                            if let job = model.coordinator.jobs.first(where: { $0.id == added.id }) { reveal(.download(job)) }
                        case .upload:
                            if let job = model.uploadJobs.first(where: { $0.id == added.id }) { reveal(.upload(job)) }
                        }
                        workspace.lastAddedTransfer = nil
                    }
                    Button { workspace.lastAddedTransfer = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("关闭提示")
                }.font(.callout).padding(10).background(.quaternary)
            }
            NetdiskFilesView(browser: workspace.browser, onUpload: presentUpload, onDownload: presentDownload,
                             pendingFiles: workspace.pendingFiles,
                             onConfirmPending: { presentUpload($0, workspace.pendingFiles) },
                             onCancelPending: {
                                 workspace.pendingFiles = []
                                 workspace.isUploadRequested = false
                             })
                .id(workspace.browser.provider)
        }
    }

    /// 来自列表的目标一次冻结；展开和刷新不能改写已经显示的确认。
    private func presentUpload(_ context: DirectoryContext, _ files: [URL]) {
        guard canPresentConfirmation else { return }
        var seen = Set<URL>()
        let selected = (workspace.pendingFiles + files).map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        uploadConfirmation = .init(account: context.account, session: context.session, directory: context.reference,
                                   trail: context.hasUnknownAncestors ? nil : context.trail, files: selected)
    }

    private func presentDownload(_ context: DirectoryContext, _ entries: [RemoteEntry]) {
        guard canPresentConfirmation, !entries.isEmpty else { return }
        downloadConfirmation = .init(account: context.account, session: context.session, entries: entries)
    }

    /// 详情关闭后再导航，避免 sheet 销毁使云端定位请求一起消失。
    private func consumeWorkspaceRequest() {
        guard canPresentConfirmation, let request = model.workspaceRequest else { return }
        model.workspaceRequest = nil
        switch request.action {
        case .browse(let provider): workspace.page = .files(provider ?? workspace.recentProvider)
        case .upload(let files):
            workspace.prepareUpload(files)
            if files.isEmpty {
                workspace.isUploadRequested = true
                presentRequestedUpload()
            }
        case .locate(let account, let directory, let focus):
            guard model.accountKey(for: account.provider) == account else {
                operationError = "请先登录原任务所属的\(account.provider.title)账号后再定位。"
                return
            }
            workspace.browser(for: account.provider).open(account: account, directory: directory, focus: focus)
            workspace.page = .files(account.provider)
        }
    }

    /// 菜单上传可以先于目录读取完成；目标可用后才打开确认，不丢失已有拖入草稿。
    private func presentRequestedUpload() {
        guard workspace.isUploadRequested, workspace.isFiles, canPresentConfirmation,
              let context = workspace.browser.context else { return }
        workspace.isUploadRequested = false
        presentUpload(context, workspace.pendingFiles)
    }

    private struct UploadPhaseSnapshot: Equatable {
        let id: UUID
        let account: AccountKey
        let phase: UploadPhase
    }

    /// 只在本轮任务终结时使目录失效，进度快照不会触发网络刷新。
    private func updateDirectoryInvalidation(_ snapshots: [UploadPhaseSnapshot]) {
        defer {
            uploadPhases = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.phase) })
            hasUploadBaseline = true
        }
        guard hasUploadBaseline else { return }
        let providers = Set(snapshots.compactMap { snapshot -> Provider? in
            let wasAddedHere = model.lastAddedUploadID == snapshot.id
            guard snapshot.phase.isTerminal,
                  (uploadPhases[snapshot.id].map { !$0.isTerminal } ?? wasAddedHere),
                  model.accountKey(for: snapshot.account.provider) == snapshot.account else { return nil }
            return snapshot.account.provider
        })
        for provider in providers { workspace.browser(for: provider).refresh() }
    }

    private func transferContent(items: [TransferListItem], scope: TransferSelection) -> some View {
        TransferListView(items: items, category: currentCategory, searchText: query, selection: $selection, scope: scope,
                         onLocateUpload: locateUpload)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty, canPresentConfirmation else { return false }
                workspace.prepareUpload(files)
                return true
            }
            .edgeBar(.top) {
                Picker("传输方向", selection: $direction) {
                    ForEach(TransferDirectionFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(width: 280).frame(maxWidth: .infinity).padding(.vertical, 8)
                Banners()
            }
            .edgeBar(.bottom) { StatusBar(direction: direction, items: items) }
            .navigationTitle(providerFilter.map { "\($0.title) · \(currentCategory.title)" } ?? currentCategory.title)
            .navigationSubtitle("\(items.count) 个任务")
            .focusedSceneValue(\.focusTaskSearch, { searchFocusRequest += 1 })
            .toolbar { transferToolbar(scope: scope) }
    }

    @ToolbarContentBuilder
    private func transferToolbar(scope: TransferSelection) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.presentAddLink() } label: { Label("添加分享链接", systemImage: "link") }
                .help("添加分享链接")
        }.solidToolbarBackground()
        if #available(macOS 26.0, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
        ToolbarItemGroup(placement: .primaryAction) {
            TransferPauseResumeButton(scope: scope)
            Button {
                inspectorPresentation.wrappedValue.toggle()
            } label: {
                Label(showsInspector ? "隐藏详情" : "显示详情", systemImage: "sidebar.trailing")
            }
            .help(showsInspector ? "隐藏详情" : "显示详情")
        }.solidToolbarBackground()
        if #available(macOS 26.0, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
        ToolbarItem(placement: .primaryAction) {
            TaskSearchField(text: $searchText, focusRequest: searchFocusRequest)
                .frame(width: min(240, max(140, (workspaceWidth - 480) / 2)))
        }.solidToolbarBackground()
    }

    /// 即使菜单携带旧快照，执行入口也只接收当前仍可见的同方向身份。
    private func perform(_ action: TransferAction, _ ids: [TransferTaskID]) {
        guard uploadCommand == nil else { return }
        let wanted = Set(ids)
        let targets = visibleItems.filter { wanted.contains($0.id) && action.allows($0, model: model) }
        if action == .copyError {
            let text = targets.compactMap { item in item.error.map { "\(item.title)：\($0)" } }.joined(separator: "\n")
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            return
        }
        if let downloadAction = action.downloadAction {
            let downloads = targets.compactMap { item -> Job? in if case .download(let job) = item { return job }; return nil }
            model.perform(downloadAction, on: model.jobs(in: downloads, allowing: downloadAction))
        }
        if let uploadAction = action.uploadAction {
            let uploads = targets.compactMap { item -> UploadJob? in if case .upload(let job) = item { return job }; return nil }
            if !uploads.isEmpty { uploadCommand = .init(action: uploadAction, jobs: uploads) }
        }
    }

    /// 下载详情保持原操作语义，但隐藏任务和上传身份不能通过此入口被误操作。
    private func requestDownloadRemoval(_ jobs: [Job], _ removal: JobRemoval) {
        requestRemoval(jobs.map { TransferTaskID(direction: .download, id: $0.id) }, removal)
    }

    private func requestRemoval(_ ids: [TransferTaskID], _ removal: JobRemoval) {
        guard uploadCommand == nil, downloadRemoval.queue.isEmpty, downloadRemoval.isIdle else { return }
        let wanted = Set(ids)
        let targets = visibleItems.filter { wanted.contains($0.id) }
        let downloads = targets.compactMap { item -> Job? in
            if case .download(let job) = item, model.canOperate(on: job) { return job }; return nil
        }
        let uploads = targets.compactMap { item -> UploadJob? in
            if case .upload(let job) = item, UploadAction.remove.allows(job) { return job }; return nil
        }
        guard !downloads.isEmpty || !uploads.isEmpty else { return }
        guard removal != .trashingFiles || uploads.isEmpty else {
            operationError = "请选择下载任务后删除本地文件。"
            return
        }
        let cleanup = Dictionary(uniqueKeysWithValues: downloads.map {
            ($0.id, $0.hasJobDirectory && !$0.isCleanedUp && model.settings.cleanupAfterDownload(for: $0.provider))
        })
        let pending = PendingTransferRemoval(downloads: downloads, uploads: uploads, removal: removal, cleanup: cleanup)
        if removal == .trashingFiles || !uploads.isEmpty || downloads.contains(where: \.isUnfinished) { pendingRemoval = pending }
        else { remove(pending) }
    }

    /// 固定本次远端清理选择；确认后再次与当前可见范围相交，避免筛选改变扩大删除范围。
    private func remove(_ pending: PendingTransferRemoval) {
        let visible = Set(visibleItems.map(\.id))
        downloadRemoval.queue = pending.downloads.filter { visible.contains(.init(direction: .download, id: $0.id)) }
            .map { .init(job: $0, removal: pending.removal, cleanup: pending.cleanup[$0.id]) }
        downloadRemoval.errors = []
        if !downloadRemoval.queue.isEmpty { Task { await drainDownloadRemovals() } }
        let uploads = pending.uploads.filter { visible.contains(.init(direction: .upload, id: $0.id)) }
        if !uploads.isEmpty { uploadCommand = .init(action: .remove, jobs: uploads) }
    }

    /// 一批任务逐个保存依据；每个任务单独清单，避免不同任务的同名路径误合并。
    private func drainDownloadRemovals() async {
        guard downloadRemoval.isIdle else { return }
        downloadRemoval.isProcessing = true
        defer { downloadRemoval.isProcessing = false }
        while let request = downloadRemoval.queue.first {
            guard visibleItems.contains(where: { $0.id == .init(direction: .download, id: request.id) }),
                  model.coordinator.jobs.contains(where: { $0.id == request.id }) else {
                downloadRemoval.queue.removeFirst()
                continue
            }
            await removeDownload(request, disposition: .preserve)
        }
        publishDownloadRemovalErrors()
    }

    /// 真正删除前由 Core 重新核对清单与归档；失败保留列表选择，不把空废纸篓失败数组当作成功。
    private func removeDownload(_ request: DownloadRemovalRequest, disposition: DownloadIntegrityDisposition) async {
        guard visibleItems.contains(where: { $0.id == .init(direction: .download, id: request.id) }) else {
            if downloadRemoval.queue.first?.id == request.id { downloadRemoval.queue.removeFirst() }
            return
        }
        do {
            try await model.remove(request.job, trashingFiles: request.removal == .trashingFiles,
                                   cleanupConfirmed: request.cleanup, integrityDisposition: disposition)
            selection.remove(.init(direction: .download, id: request.id))
        } catch {
            downloadRemoval.errors.append(request.job.title + "：" + error.localizedDescription)
        }
        if downloadRemoval.queue.first?.id == request.id { downloadRemoval.queue.removeFirst() }
    }

    /// 完成或取消本批次时只发布已经发生的失败；清空缓冲，避免下一次操作重复提示。
    private func publishDownloadRemovalErrors() {
        guard !downloadRemoval.errors.isEmpty else { return }
        operationError = downloadRemoval.errors.joined(separator: "\n")
        downloadRemoval.errors = []
    }

    /// 独立上传 actor 操作按当前范围路由，确认／错误状态由主窗口持有，菜单关闭不丢失。
    private func performUpload(_ request: UploadCommand) async {
        defer { uploadCommand = nil }
        guard let coordinator = model.uploadCoordinator else { operationError = "请稍后重试上传。"; return }
        var failures: [String] = []
        for requested in request.jobs {
            if Task.isCancelled { return }
            let key = TransferTaskID(direction: .upload, id: requested.id)
            guard visibleItems.contains(where: { $0.id == key }),
                  let job = model.uploadJobs.first(where: { $0.id == requested.id }), request.action.allows(job) else { continue }
            do {
                switch request.action {
                case .pause: try await coordinator.pause(job.id)
                case .resume: try await coordinator.resume(job.id)
                case .retry: try await coordinator.retry(job.id)
                case .cancel: try await coordinator.cancel(job.id)
                case .remove: try await coordinator.remove(job.id)
                case .prioritize: try await coordinator.prioritize(job.id)
                case .reconcile: try await coordinator.reconcile(job.id)
                }
            } catch {
                guard !Task.isCancelled else { return }
                failures.append("\(job.title)：\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { operationError = failures.joined(separator: "\n") }
    }

    private func inspect(_ ids: [TransferTaskID]) {
        let wanted = Set(ids)
        let targets = visibleItems.filter { wanted.contains($0.id) }
        guard !targets.isEmpty else { return }
        selection = Set(targets.map(\.id))
        inspectorPresentation.wrappedValue = true
    }

    /// 新增任务定位原来源，清理会遮住它的筛选；全部传输视图保持全部，不强迫切换方向。
    private func reveal(_ item: TransferListItem) {
        workspace.page = .transfers(.all)
        switch item {
        case .download(let job):
            if direction == .upload { direction = .download }
            providerFilter = job.provider
        case .upload(let job):
            if direction == .download { direction = .upload }
            providerFilter = job.account.provider
        }
        category = .all; searchText = ""; selection = [item.id]
    }
    /// 重复提醒主动定位原批次，复用父页筛选与选中状态，不受新增任务一次性标记限制。
    private func locateUpload(_ id: UUID) {
        guard let job = model.uploadJobs.first(where: { $0.id == id }) else {
            operationError = "原上传任务已移除。可选择继续当前任务。"
            return
        }
        reveal(.upload(job))
    }

    private func revealNewUpload() {
        guard let id = model.lastAddedUploadID, id != revealedUploadID,
              let job = model.uploadJobs.first(where: { $0.id == id }) else { return }
        revealedUploadID = id
        if workspace.isFiles { workspace.lastAddedTransfer = .init(direction: .upload, id: id) }
        else { reveal(.upload(job)) }
    }

    #if DEBUG
    private func showDemoSelection() async {
        guard DemoData.isEnabled else { return }
        while !model.coordinator.isStarted {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        if let value = DemoData.category.flatMap(JobCategory.init(rawValue:)) { category = value }
        if let title = DemoData.selectedTitle, let job = model.coordinator.jobs.first(where: { $0.title == title }) {
            selection = [.init(direction: .download, id: job.id)]; isInspectorPresented = true
        }
    }
    #endif
}

private struct PendingTransferRemoval {
    let downloads: [Job]
    let uploads: [UploadJob]
    let removal: JobRemoval
    let cleanup: [UUID: Bool]
    var title: String {
        let count = downloads.count + uploads.count
        return removal == .trashingFiles ? "移除 \(count) 个任务并删除下载文件？" : "移除 \(count) 个任务记录？"
    }
    var message: String {
        var lines: [String] = []
        if !downloads.isEmpty {
            lines.append(removal == .trashingFiles ? "下载：已下载文件移到废纸篓；未完成的下载取消并删除已下载部分。" : "下载：保留已完成文件；未完成的下载取消并删除已下载部分。")
            for provider in Provider.allCases {
                let targets = downloads.filter { $0.provider == provider }
                guard !targets.isEmpty else { continue }
                let count = targets.count { $0.hasJobDirectory && !$0.isCleanedUp && cleanup[$0.id] == true }
                lines.append("\(provider.title)：清理 \(count) 个任务转存目录。")
            }
        }
        if !uploads.isEmpty { lines.append("上传：移除任务后，Mac 和网盘中的文件会保留。") }
        return lines.joined(separator: "\n")
    }
}

private struct TransferPauseResumeButton: View {
    let scope: TransferSelection
    @Environment(AppModel.self) private var model
    var body: some View {
        let paused = scope.visibleItems.filter { TransferAction.pause.allows($0, model: model) }
        let resumed = scope.visibleItems.filter { TransferAction.resume.allows($0, model: model) }
        let action: TransferAction = paused.isEmpty ? .resume : .pause
        let targets = paused.isEmpty ? resumed : paused
        Button { scope.onAction(action, targets.map(\.id)) } label: {
            Label(action == .pause ? "暂停当前列表" : "继续当前列表", systemImage: action == .pause ? "pause.fill" : "play.fill")
        }
        .disabled(scope.isBusy || targets.isEmpty)
        .help("\(action == .pause ? "暂停" : "继续")当前列表的 \(targets.count) 个传输任务")
    }
}

private struct TransferInspector: View {
    let scope: TransferSelection
    let onDownloadRemove: ([Job], JobRemoval) -> Void
    private var downloads: [Job] {
        scope.selectedItems.compactMap { if case .download(let job) = $0 { return job }; return nil }
    }
    var body: some View {
        if scope.selectedItems.isEmpty { ContentUnavailableView("未选择任务", systemImage: "sidebar.trailing") }
        else if downloads.count == scope.selectedItems.count {
            JobInspector(jobs: downloads, onAction: { jobs, action in
                scope.onAction(TransferAction(action), jobs.map { .init(direction: .download, id: $0.id) })
            }, onRemove: onDownloadRemove)
        }
        else if scope.selectedItems.count == 1, case .upload(let job) = scope.selectedItems[0] {
            UploadInspector(jobID: job.id, title: job.title, scope: scope).id(job.id)
        } else {
            ContentUnavailableView {
                Label("已选择 \(scope.selectedItems.count) 个传输任务", systemImage: "square.stack")
            } actions: { VStack { TransferActionsMenu(scope: scope) }.buttonStyle(.bordered) }
        }
    }
}

/// 直接汇总当前可见任务，分类、搜索、统计和批量命令共用同一范围。
private struct StatusBar: View {
    let direction: TransferDirectionFilter
    let items: [TransferListItem]
    @Environment(AppModel.self) private var model
    @State private var showsStatistics = false

    var body: some View {
        let jobs = items.compactMap { item -> Job? in if case .download(let job) = item { return job }; return nil }
        let uploads = items.compactMap { item -> UploadJob? in if case .upload(let job) = item { return job }; return nil }
        let uploadedBytes = uploads.reduce(Int64(0)) { $0 + $1.completedBytes }
        let uploadTotalBytes = uploads.reduce(Int64(0)) { $0 + $1.totalBytes }
        let uploadSummary = "上传 \(uploadedBytes.byteCount) / \(uploadTotalBytes.byteCount)"
        let activities = jobs.map { model.coordinator.activity(of: $0.id) }
        let progress = JobProgress(
            receivedBytes: activities.reduce(0) { $0 + $1.progress.receivedBytes },
            totalBytes: activities.reduce(0) { $0 + $1.progress.totalBytes },
            bytesPerSecond: activities.reduce(0) { $0 + $1.progress.bytesPerSecond })
        let totalFiles = jobs.reduce(0) { $0 + $1.files.count }
        let completedFiles = activities.reduce(0) { $0 + $1.completedFileCount }
        let preparing = jobs.count { $0.phase == .transferring }
        let summary = preparing == 0 ? progress.summary : [progress.sizeSummary, progress.speedText].compactMap { $0 }.joined(separator: " · ")
        if !jobs.isEmpty || !uploads.isEmpty {
            HStack {
                Label(direction.title, systemImage: direction == .download ? "arrow.down" : direction == .upload ? "arrow.up" : "arrow.up.arrow.down")
                    .fixedSize()
                Text([jobs.isEmpty ? nil : (direction == .all ? "下载 " : "") + summary,
                      uploads.isEmpty ? nil : (direction == .all ? "上传 " : "") + "\(uploadedBytes.byteCount) / \(uploadTotalBytes.byteCount)"].compactMap { $0 }.joined(separator: " · "))
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text([jobs.isEmpty ? nil : "\(completedFiles)/\(totalFiles) 文件",
                      uploads.isEmpty ? nil : "上传 \(uploads.count) 批次"].compactMap { $0 }.joined(separator: " · "))
                    .fixedSize()
                Button {
                    showsStatistics.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .help("\(direction.title)统计")
                .accessibilityLabel("\(direction.title)统计")
                .popover(isPresented: $showsStatistics) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(direction.title).font(.headline)
                        if !uploads.isEmpty {
                            LabeledContent("上传已确认 / 总大小", value: uploadSummary)
                            LabeledContent("上传批次", value: "\(uploads.filter { $0.phase == .completed }.count) 完成 / \(uploads.count) 总计")
                        }
                        if !jobs.isEmpty {
                            ProgressView(value: progress.fractionCompleted)
                            LabeledContent("已下载 / 已确定总大小", value: progress.sizeSummary)
                            LabeledContent("总速度", value: progress.speedText ?? "—")
                            LabeledContent("预计剩余时间", value: preparing == 0 ? progress.remainingTimeText ?? "—" : "等待文件准备完成")
                            LabeledContent("已完成文件", value: "\(completedFiles) / \(totalFiles)")
                            if preparing > 0 {
                                Text("\(preparing) 个任务正在准备。")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .frame(minWidth: 300)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }
}

/// 原生搜索框直接回写当前窗口状态，工具栏或提示栏更新后仍保持同一条输入链路。
struct TaskSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    var placeholder = "搜索任务"

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocusRequest != focusRequest, let window = field.window {
            context.coordinator.lastFocusRequest = focusRequest
            window.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    /// 搜索框使用稳定的工具栏尺寸，窗口缩放不改变相邻项目的位置约束。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 104, height: nsView.intrinsicContentSize.height)
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        field.delegate = nil
        field.target = nil
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var lastFocusRequest = 0

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        @objc func search(_ field: NSSearchField) {
            text.wrappedValue = field.stringValue
        }
    }
}

private struct TaskSearchFocusKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var workspaceIsFiles: Bool? {
        get { self[WorkspaceIsFilesKey.self] }
        set { self[WorkspaceIsFilesKey.self] = newValue }
    }
}

private struct WorkspaceIsFilesKey: FocusedValueKey {
    typealias Value = Bool
}

private struct WorkspaceSelectAllKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var selectWorkspaceItems: (() -> Void)? {
        get { self[WorkspaceSelectAllKey.self] }
        set { self[WorkspaceSelectAllKey.self] = newValue }
    }
}

extension FocusedValues {
    var focusTaskSearch: (() -> Void)? {
        get { self[TaskSearchFocusKey.self] }
        set { self[TaskSearchFocusKey.self] = newValue }
    }
}

private struct TransferInspectorPresentedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var transferInspectorPresented: Binding<Bool>? {
        get { self[TransferInspectorPresentedKey.self] }
        set { self[TransferInspectorPresentedKey.self] = newValue }
    }
}
