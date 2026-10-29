import BaiduKit
import FerryCore
import SwiftUI

/// 方向、来源、分类与搜索均由父页筛选；两类任务共享一个原生 List 和选中集合。
struct TransferListView: View {
    let items: [TransferListItem]
    let category: JobCategory
    let searchText: String
    @Binding var selection: Set<TransferTaskID>
    let scope: TransferSelection
    let onLocateUpload: (UUID) -> Void
    @Environment(AppModel.self) private var model
    @FocusState private var isListFocused: Bool

    var body: some View {
        if items.isEmpty {
            if !searchText.isEmpty { ContentUnavailableView("试试其他关键词", systemImage: "magnifyingglass") }
            else if model.coordinator.jobs.isEmpty, model.uploadJobs.isEmpty, model.account == nil, model.quark.account == nil {
                ContentUnavailableView {
                    Label("添加传输任务", systemImage: "tray.and.arrow.down")
                } actions: {
                    if let provider = scope.providerFilter {
                        Button("登录\(provider.title)") { model.presentLogin(for: provider) }
                    } else {
                        Button("登录百度网盘") { model.presentLogin(for: .baidu) }
                        Button("登录夸克网盘") { model.presentLogin(for: .quark) }
                    }
                }
            } else { ContentUnavailableView(category.emptyTitle, systemImage: category.systemImage) }
        } else {
            List(selection: $selection) {
                ForEach(rows) { row in
                    let item = row.item
                    Group {
                        switch item {
                        case .download(let job):
                            JobRow(job: job, showsProvider: scope.providerFilter == nil, onAction: { job, action in
                                scope.onAction(TransferAction(action), [.init(direction: .download, id: job.id)])
                            })
                        case .upload(let job):
                            UploadRow(job: job, showsProvider: scope.providerFilter == nil,
                                      onAction: { scope.onAction($0, [item.id]) },
                                      onLocateDuplicate: onLocateUpload,
                                      onResumeDuplicate: { scope.onAction(.resume, [item.id]) },
                                      onInspect: { scope.onInspect([item.id]) })
                        }
                    }
                    .tag(item.id)
                }
            }
            .focused($isListFocused)
            .simultaneousGesture(TapGesture().onEnded { isListFocused = true })
            .contextMenu(forSelectionType: TransferTaskID.self) { ids in
                TransferActionsMenu(scope: scope.selecting(ids))
            } primaryAction: { ids in
                let targets = scope.visibleItems.filter { ids.contains($0.id) }
                if targets.contains(where: { $0.id.direction == .upload }) { scope.onInspect(targets.map(\.id)) }
                else { scope.onAction(.reveal, targets.map(\.id)) }
            }
            .onDeleteCommand { scope.onRemove(scope.selectedItems.map(\.id), .keepingFiles) }
        }
    }

    /// 从当前账号和移除活动推导行结构；观察展示需要的状态，业务选择沿用任务 ID。
    private var rows: [TransferRowItem] { items.map { .init(item: $0, model: model) } }
}

/// 原生 List 会缓存行高；只有内容结构变化时重建展示行，选中与命令仍使用稳定任务身份。
fileprivate struct TransferRowLayoutID: Hashable {
    let task: TransferTaskID
    var hasProgress = false
    var hasDuplicate = false
    var hasPartialFailure = false
    var isRemoving = false
    var needsAccountLogin = false
    var hasWarning = false
    var error: String?
}

/// 临时只读呈现项；结构变化更新原生 List 行高，进度字节变化保持同一展示身份。
fileprivate struct TransferRowItem: Identifiable {
    let item: TransferListItem
    let id: TransferRowLayoutID

    init(item: TransferListItem, model: AppModel) {
        self.item = item
        switch item {
        case .download(let job):
            let isRemoving = model.coordinator.removingJobs.contains(job.id)
            let needsAccountLogin = job.accountKey.map { model.accountKey(for: job.provider) != $0 } ?? false
            id = .init(task: item.id, hasProgress: job.phase != .completed || isRemoving,
                       isRemoving: isRemoving, needsAccountLogin: needsAccountLogin,
                       hasWarning: job.warning != nil, error: job.error)
        case .upload(let job):
            id = .init(task: item.id, hasProgress: !job.phase.isTerminal,
                       hasDuplicate: job.duplicateOfJobID != nil, hasPartialFailure: job.hasPartialFailure,
                       error: job.error)
        }
    }
}

/// 只读投影，不复制任何传输执行状态；相同 UUID 在两个方向也具有不同身份。
enum TransferListItem: Identifiable {
    case download(Job)
    case upload(UploadJob)
    var id: TransferTaskID {
        switch self {
        case .download(let job): .init(direction: .download, id: job.id)
        case .upload(let job): .init(direction: .upload, id: job.id)
        }
    }
    var createdAt: Date {
        switch self { case .download(let job): job.createdAt; case .upload(let job): job.createdAt }
    }
    var error: String? {
        switch self { case .download(let job): job.error; case .upload(let job): job.error }
    }
    var title: String {
        switch self { case .download(let job): job.title; case .upload(let job): job.title }
    }
}

enum TransferDirectionFilter: String, CaseIterable, Identifiable {
    case all, download, upload
    var id: Self { self }
    var title: String {
        switch self { case .all: "全部传输"; case .download: "下载"; case .upload: "上传" }
    }
}

/// 同一操作按任务方向路由到原下载调度或上传 actor，上传不具有删除本地文件动作。
enum TransferAction: CaseIterable {
    case pause, resume, retry, prioritize, reconcile, cancel, reveal, copyError
    /// 下载行和详情复用同一个方向明确的执行入口，旧回调也重新核对当前可见范围。
    init(_ action: JobAction) {
        switch action {
        case .pause: self = .pause
        case .resume: self = .resume
        case .retry: self = .retry
        case .reveal: self = .reveal
        }
    }
    var title: String {
        switch self {
        case .pause: "暂停"
        case .resume: "继续"
        case .retry: "重试失败项"
        case .prioritize: "优先上传"
        case .reconcile: "核对远端结果"
        case .cancel: "取消上传"
        case .reveal: "在 Finder 中显示"
        case .copyError: "复制错误"
        }
    }
    var downloadAction: JobAction? {
        switch self { case .pause: .pause; case .resume: .resume; case .retry: .retry; case .reveal: .reveal; default: nil }
    }
    var systemImage: String {
        switch self {
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .retry, .reconcile: "arrow.clockwise"
        case .prioritize: "arrow.up.to.line"
        case .cancel: "xmark"
        case .reveal: "magnifyingglass"
        case .copyError: "doc.on.doc"
        }
    }
    var uploadAction: UploadAction? {
        switch self {
        case .pause: .pause; case .resume: .resume; case .retry: .retry
        case .prioritize: .prioritize; case .reconcile: .reconcile; case .cancel: .cancel
        default: nil
        }
    }
    func allows(_ item: TransferListItem, model: AppModel) -> Bool {
        if self == .copyError { return item.error != nil }
        switch item {
        case .download(let job):
            guard let action = downloadAction else { return false }
            return model.canOperate(on: job) && job.allows(action)
        case .upload(let job):
            return model.uploadCoordinator != nil && uploadAction?.allows(job) == true
        }
    }
}

/// 主窗口持有确认与错误；菜单只携带筛选快照和命令回调，关闭菜单不会丢失对话框。
struct TransferSelection {
    let selectedItems: [TransferListItem]
    let visibleItems: [TransferListItem]
    let providerFilter: Provider?
    let isBusy: Bool
    let onAction: (TransferAction, [TransferTaskID]) -> Void
    let onRemove: ([TransferTaskID], JobRemoval) -> Void
    let onInspect: ([TransferTaskID]) -> Void

    func selecting(_ ids: Set<TransferTaskID>) -> Self {
        .init(selectedItems: visibleItems.filter { ids.contains($0.id) }, visibleItems: visibleItems,
              providerFilter: providerFilter, isBusy: isBusy, onAction: onAction, onRemove: onRemove, onInspect: onInspect)
    }
}

struct TransferActionsMenu: View {
    let scope: TransferSelection
    var showsUnavailable = false
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(TransferAction.allCases, id: \.self) { action in
            let targets = scope.selectedItems.filter { action.allows($0, model: model) }
            if showsUnavailable || !targets.isEmpty {
                actionButton(action, targets: targets)
            }
        }
        if showsUnavailable || !scope.selectedItems.isEmpty {
            Divider()
            Button("查看详情") { scope.onInspect(scope.selectedItems.map(\.id)) }
                .disabled(scope.selectedItems.isEmpty)
            Button("移除记录", role: .destructive) { scope.onRemove(scope.selectedItems.map(\.id), .keepingFiles) }
                .disabled(scope.isBusy || !scope.selectedItems.contains(where: canRemove))
            let downloads = scope.selectedItems.compactMap { item -> Job? in
                if case .download(let job) = item { return job }; return nil
            }
            // 含上传的混合选择不展示本地删除，避免将其误解为删除上传原文件。
            if !downloads.isEmpty && downloads.count == scope.selectedItems.count && model.canTrashFiles(of: downloads) {
                Button("移除并删除下载文件", role: .destructive) { scope.onRemove(scope.selectedItems.map(\.id), .trashingFiles) }
                    .disabled(scope.isBusy)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: TransferAction, targets: [TransferListItem]) -> some View {
        let button = Button(action.title) { scope.onAction(action, targets.map(\.id)) }
            .disabled(scope.isBusy || targets.isEmpty)
        if showsUnavailable {
            switch action {
            case .pause: button.keyboardShortcut("p", modifiers: [.command, .shift])
            case .resume: button.keyboardShortcut("r", modifiers: [.command, .shift])
            case .retry: button.keyboardShortcut("r", modifiers: [.command])
            default: button
            }
        } else { button }
    }

    private func canRemove(_ item: TransferListItem) -> Bool {
        switch item {
        case .download(let job): model.canOperate(on: job)
        case .upload(let job): UploadAction.remove.allows(job)
        }
    }
}

/// 一个任务：图标、标题、进度条、状态，以及行尾的主要操作。
struct JobRow: View {
    let job: Job
    var showsProvider = true
    let onAction: (Job, JobAction) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let activity = model.coordinator.activity(of: job.id)
        let isRemoving = model.coordinator.removingJobs.contains(job.id)
        TransferRowContent(title: job.title, systemImage: job.systemImage,
                           provider: showsProvider ? job.provider : nil,
                           summary: summary(activity: activity, isRemoving: isRemoving)) {
            JobProgressBar(job: job, activity: activity, isRemoving: isRemoving)
        } actions: {
            if let action = job.primaryAction {
                JobActionButton(job: job, action: action, onAction: onAction)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .imageScale(.large)
            }
        } supplement: {
            if let error = job.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error)
            }
            if let owner = job.accountKey, model.accountKey(for: job.provider) != owner {
                Button("登录任务所属账号") { model.presentLogin(for: job.provider) }
                    .font(.caption).buttonStyle(.borderless)
            }
            if let warning = job.warning {
                Text(warning == "没有删除网盘中的转存文件：没有全部文件的可信内容校验结果，已保留转存文件" ? "转存文件已保留" : warning)
                    .font(.caption).foregroundStyle(.orange).lineLimit(1).help(warning)
            }
        }
    }

    /// 主列表只表达当前结果、有效字节进度和速度；详细路径及剩余时间留在详情。
    private func summary(activity: JobActivity, isRemoving: Bool) -> String {
        let status: String
        if isRemoving { status = "正在移除" }
        else if job.files.contains(where: { model.coordinator.verifyingLocalFiles.contains($0.id) }) {
            status = "正在完成"
        } else {
            status = job.statusText(isRunning: activity.isRunning, cleansUp: model.settings.cleanupAfterDownload(for: job.provider))
        }
        var parts = [status]
        if !job.files.isEmpty {
            parts.append(job.phase == .completed ? activity.progress.totalBytes.byteCount : activity.progress.sizeSummary)
        }
        if job.phase == .downloading, !job.isPaused, activity.isRunning,
           let speed = activity.progress.speedText { parts.append(speed) }
        return parts.joined(separator: " · ")
    }
}

/// 上传和下载共用的信息层级；业务状态及可执行动作由调用方提供。
struct TransferRowContent<Progress: View, Actions: View, Supplement: View>: View {
    let title: String
    let systemImage: String
    let provider: Provider?
    let summary: String
    @ViewBuilder let progress: () -> Progress
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let supplement: () -> Supplement

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2).foregroundStyle(.secondary).frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title).font(.headline).lineLimit(1).truncationMode(.middle).help(title)
                    Spacer(minLength: 8)
                    actions()
                }
                progress()
                HStack(spacing: 6) {
                    if let provider {
                        ProviderIcon(provider: provider, size: 14, accessibilityDescription: provider.title)
                            .help(provider.title)
                    }
                    Text(summary).lineLimit(1).truncationMode(.tail).help(summary)
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                supplement()
            }
        }
        .padding(.vertical, 5)
    }
}

private struct TransferSelectionKey: FocusedValueKey {
    typealias Value = TransferSelection
}

extension FocusedValues {
    var transferSelection: TransferSelection? {
        get { self[TransferSelectionKey.self] }
        set { self[TransferSelectionKey.self] = newValue }
    }
}

/// 移除任务时怎样处理已下载的文件。没完成的文件下载总是取消，并删除已下载的部分。
enum JobRemoval {
    /// 已下载的文件留在本地。
    case keepingFiles
    /// 已下载的文件移到废纸篓。
    case trashingFiles
}

/// 对一个任务的操作。
enum JobAction: CaseIterable {
    case pause
    case resume
    case retry
    case reveal

    var title: String {
        switch self {
        case .pause: "暂停"
        case .resume: "继续"
        case .retry: "重试"
        case .reveal: "在 Finder 中显示"
        }
    }

    var systemImage: String {
        switch self {
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .retry: "arrow.clockwise"
        case .reveal: "magnifyingglass"
        }
    }
}

extension Job {
    /// 任务行行尾的操作：下载中为暂停，已暂停为继续，失败为重试，已完成为在 Finder 中显示。转存中（网盘任务：准备中）没有操作。
    var primaryAction: JobAction? {
        switch phase {
        case .transferring: nil
        case .downloading: isPaused ? .resume : .pause
        case .failed: .retry
        case .completed: revealURLs.isEmpty ? nil : .reveal
        }
    }

    /// 任务的阶段是否允许 `action`。不考虑启动恢复和移除（见 `AppModel.canOperate(on:)`）。
    func allows(_ action: JobAction) -> Bool {
        switch action {
        case .pause: phase == .downloading && !isPaused
        case .resume: phase == .downloading && isPaused
        case .retry: primaryAction == .retry
        case .reveal: !revealURLs.isEmpty
        }
    }

    /// 标题或任意文件名包含 `text`，不区分大小写。
    func matches(_ text: String) -> Bool {
        title.localizedCaseInsensitiveContains(text) || files.contains { $0.name.localizedCaseInsensitiveContains(text) }
    }

    var systemImage: String {
        source.isSingleFile ? FileIcon.systemName(for: title, isDirectory: false) : "folder"
    }
}

/// 执行一个任务操作的按钮。启动恢复完成前和移除期间不可用。
struct JobActionButton: View {
    let job: Job
    let action: JobAction
    let onAction: (Job, JobAction) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            onAction(job, action)
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
        .help(action.title)
        .disabled(!model.canOperate(on: job))
    }
}

/// 任务的进度条。转存中和移除期间为不确定进度，下载失败为红色，已暂停为灰色。已完成的任务没有进度条。
struct JobProgressBar: View {
    let job: Job
    let activity: JobActivity
    let isRemoving: Bool

    var body: some View {
        if job.phase == .transferring || isRemoving {
            ProgressView().progressViewStyle(.linear)
        } else if job.phase != .completed {
            ProgressView(value: activity.progress.fractionCompleted)
                .tint(tint)
        }
    }

    private var tint: Color? {
        if job.phase == .failed(.download) { return .red }
        if job.phase == .downloading && job.isPaused { return .gray }
        return nil
    }
}

/// 任务的错误、“属于另一个百度账号”的说明和警告。
struct JobNotes: View {
    let job: Job
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = job.error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        if let owner = job.accountKey, model.accountKey(for: job.provider) != owner {
            Text("这个任务属于\(job.provider.title)账号“\(job.accountName ?? owner.accountID)”（\(owner.accountID)）。登录原账号后可以继续。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("登录任务所属的\(job.provider.title)账号") { model.presentLogin(for: job.provider) }
                .font(.caption)
        }
        if let warning = job.warning {
            Text(warning == "没有删除网盘中的转存文件：没有全部文件的可信内容校验结果，已保留转存文件" ? "转存文件已保留" : warning)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
