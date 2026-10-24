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
    @Environment(AppModel.self) private var model
    @FocusState private var isListFocused: Bool

    var body: some View {
        if items.isEmpty {
            if !searchText.isEmpty { ContentUnavailableView.search(text: searchText) }
            else if model.coordinator.jobs.isEmpty, model.uploadJobs.isEmpty, model.account == nil, model.quark.account == nil {
                ContentUnavailableView {
                    Label("没有任务", systemImage: "tray.and.arrow.down")
                } actions: {
                    if let provider = scope.providerFilter {
                        Button("登录\(provider.title)…") { model.presentLogin(for: provider) }
                    } else {
                        Button("登录百度网盘…") { model.presentLogin(for: .baidu) }
                        Button("登录夸克网盘…") { model.presentLogin(for: .quark) }
                    }
                }
            } else { ContentUnavailableView(category.emptyTitle, systemImage: category.systemImage) }
        } else {
            List(items, selection: $selection) { item in
                switch item {
                case .download(let job): JobRow(job: job)
                case .upload(let job): UploadRow(job: job)
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
            Button("查看详情…") { scope.onInspect(scope.selectedItems.map(\.id)) }
                .disabled(scope.selectedItems.isEmpty)
            Button("移除记录…", role: .destructive) { scope.onRemove(scope.selectedItems.map(\.id), .keepingFiles) }
                .disabled(scope.isBusy || !scope.selectedItems.contains(where: canRemove))
            let downloads = scope.selectedItems.compactMap { item -> Job? in
                if case .download(let job) = item { return job }; return nil
            }
            // 含上传的混合选择不展示本地删除，避免将其误解为删除上传原文件。
            if !downloads.isEmpty && downloads.count == scope.selectedItems.count && model.canTrashFiles(of: downloads) {
                Button("移除并删除下载文件…", role: .destructive) { scope.onRemove(scope.selectedItems.map(\.id), .trashingFiles) }
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
    @Environment(AppModel.self) private var model

    var body: some View {
        let activity = model.coordinator.activity(of: job.id)
        let isRemoving = model.coordinator.removingJobs.contains(job.id)
        HStack(spacing: 12) {
            Image(systemName: job.systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                JobProgressBar(job: job, activity: activity, isRemoving: isRemoving)
                JobStatusLine(job: job, activity: activity, isRemoving: isRemoving)
                JobNotes(job: job)
            }
            if let action = job.primaryAction {
                JobActionButton(job: job, action: action)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .imageScale(.large)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 对一组任务的操作，用于右键菜单和菜单栏的“任务”菜单。每个操作只作用于其中可以执行它的任务。
///
/// 按 HIG，右键菜单隐藏不可用的操作；菜单栏菜单保留它们并显示为不可用。
struct JobActionsMenu: View {
    let jobs: [Job]
    /// 为 true 时显示不可用的操作（菜单栏菜单）。
    var showsUnavailable = false
    /// 请求移除任务。调用方决定是否先确认。
    let onRemove: ([Job], JobRemoval) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(JobAction.allCases, id: \.self) { action in
            let targets = model.jobs(in: jobs, allowing: action)
            if showsUnavailable || !targets.isEmpty {
                Button {
                    model.perform(action, on: targets)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .disabled(targets.isEmpty)
            }
        }
        if showsUnavailable || !jobs.isEmpty {
            Divider()
            Button(role: .destructive) {
                onRemove(jobs, .keepingFiles)
            } label: {
                Label("移除", systemImage: "xmark")
            }
            .disabled(!jobs.contains { model.canOperate(on: $0) })
            let canTrash = model.canTrashFiles(of: jobs)
            if showsUnavailable || canTrash {
                Button(role: .destructive) {
                    onRemove(jobs, .trashingFiles)
                } label: {
                    Label("移除并删除文件…", systemImage: "trash")
                }
                .disabled(!canTrash)
            }
        }
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
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.perform(action, on: [job])
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

/// 任务的状态行：来源图标、状态，以及已下载 / 总大小 · 速度 · 剩余时间。
struct JobStatusLine: View {
    let job: Job
    let activity: JobActivity
    let isRemoving: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: job.provider == .baidu ? "b.circle" : "q.circle")
                .help(job.provider.title + (job.isNetdisk ? " · 账号内文件" : " · 分享链接"))
                .accessibilityLabel(job.provider.title + (job.isNetdisk ? "，账号内文件" : "，分享链接"))
            Text(isRemoving
                 ? "正在移除…"
                 : job.statusText(isRunning: activity.isRunning, cleansUp: model.settings.cleanupAfterDownload(for: job.provider)))
            if !job.files.isEmpty {
                Text(job.phase == .downloading && !job.isPaused ? activity.progress.summary : activity.progress.sizeSummary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
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
            Button("登录任务所属的\(job.provider.title)账号…") { model.presentLogin(for: job.provider) }
                .font(.caption)
        }
        if let warning = job.warning {
            Text(warning)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
