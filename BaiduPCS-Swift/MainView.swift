import AppKit
import FerryCore
import SwiftUI

/// 主窗口的内容：侧边栏（任务分类和账号）、任务列表和详情栏。
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var category: JobCategory? = .all
    @State private var providerFilter: Provider?
    @State private var direction: TransferDirection = .download
    @State private var addedJobNotice: Job?
    @State private var selection: Set<Job.ID> = []
    @SceneStorage("isInspectorPresented") private var isInspectorPresented = false
    @State private var searchText = ""
    @State private var searchFocusRequest = 0
    /// 等待确认的移除。
    @State private var pendingRemoval: PendingRemoval?

    var body: some View {
        let current = category ?? .all
        let providerJobs = direction == .download ? model.coordinator.jobs.filter { providerFilter == nil || $0.provider == providerFilter } : []
        let providerUploads = direction == .upload ? model.uploadJobs.filter { providerFilter == nil || $0.account.provider == providerFilter } : []
        let categoryJobs = providerJobs.filter(current.contains)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let jobs = query.isEmpty ? categoryJobs : categoryJobs.filter { $0.matches(query) }
        let uploads = providerUploads.filter { current.contains($0) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.accountName.localizedCaseInsensitiveContains(query)) }
        // 只算列表中显示的任务。切换分类或搜索后，看不到的任务不再算作选中。
        let selectedJobs = jobs.filter { selection.contains($0.id) }
        NavigationSplitView {
            SidebarView(selection: $category, providerFilter: $providerFilter, jobs: providerJobs, uploadJobs: providerUploads)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
        } detail: {
            Group {
                if direction == .upload { UploadListView(jobs: uploads) }
                else { JobListView(jobs: jobs, category: current, providerFilter: providerFilter, searchText: query, selection: $selection, onRemove: requestRemoval) }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .edgeBar(.top) {
                    Picker("传输方向", selection: $direction) {
                        Text("下载").tag(TransferDirection.download)
                        Text("上传").tag(TransferDirection.upload)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    Banners()
                    if let job = addedJobNotice {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("已添加\(job.provider.title)任务“\(job.title)”")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(job.title)
                            Button("查看任务") { revealAddedJob(job) }
                            Button("关闭") { addedJobNotice = nil }
                        }
                        .padding(.horizontal)
                        .frame(height: 40)
                    }
                }
                .edgeBar(.bottom) { StatusBar() }
                .navigationTitle(providerFilter.map { "\($0.title) · \(current.title)" } ?? current.title)
                .navigationSubtitle("\(jobs.count + uploads.count) 个任务")
                .inspector(isPresented: $isInspectorPresented) {
                    JobInspector(jobs: selectedJobs, onRemove: requestRemoval)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                model.presentAddLink()
                            } label: {
                                Label("添加分享链接…", systemImage: "link")
                            }
                            Button {
                                model.presentNetdiskDownload()
                            } label: {
                                Label("从我的网盘下载…", systemImage: "cloud")
                            }
                            Button {
                                model.presentUpload(provider: providerFilter)
                            } label: {
                                Label("上传文件…", systemImage: "arrow.up.doc")
                            }
                        } label: {
                            Label("添加任务", systemImage: "plus")
                        }
                        .help("添加任务")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if direction == .download { PauseResumeAllButton(jobs: jobs) }
                        else { UploadPauseResumeAllButton(jobs: uploads) }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isInspectorPresented.toggle()
                        } label: {
                            Label(isInspectorPresented ? "隐藏详情" : "显示详情", systemImage: "sidebar.trailing")
                        }
                        .help(isInspectorPresented ? "隐藏详情" : "显示详情")
                        .disabled(direction == .upload)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        TaskSearchField(text: $searchText, focusRequest: searchFocusRequest)
                            .frame(width: 104)
                    }
                }
        }
        .frame(minWidth: 640, minHeight: 400)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, model.sheet == nil else { return false }
            model.presentUpload(provider: providerFilter, files: files)
            return true
        }
        #if DEBUG
        .task { await showDemoSelection() }
        #endif
        .onChange(of: model.hasPendingNetdiskDownloadRequest, initial: true) { _, requested in
            if requested { model.presentRequestedNetdiskDownload() }
        }
        .onChange(of: model.sheet) { _, sheet in
            if sheet == nil { model.presentRequestedNetdiskDownload() }
        }
        .onChange(of: direction) { _, _ in selection = []; isInspectorPresented = false }
        .onChange(of: model.lastAddedUploadID) { _, id in
            guard let id, let job = model.uploadJobs.first(where: { $0.id == id }) else { return }
            direction = .upload; providerFilter = job.account.provider; category = .all; searchText = ""
        }
        .focusedSceneValue(\.jobSelection, JobSelection(jobs: selectedJobs, visibleJobs: jobs, providerFilter: providerFilter, onRemove: requestRemoval))
        .focusedSceneValue(\.focusTaskSearch, { searchFocusRequest += 1 })
        // 文本框优先处理自己的全选；其余主窗口响应只选择当前筛选列表。
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            selection = Set(jobs.map(\.id))
        }
        .onChange(of: jobs.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .onChange(of: model.coordinator.jobs.map(\.id)) { _, ids in
            if let notice = addedJobNotice, !ids.contains(notice.id) { addedJobNotice = nil }
        }
        .onChange(of: model.lastAddedJobID) { _, id in
            guard let id, let job = model.coordinator.jobs.first(where: { $0.id == id }) else { return }
            if jobs.contains(where: { $0.id == id }) { selection = [id] } else { addedJobNotice = job }
        }
        .confirmationDialog(
            pendingRemoval?.title ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { pending in
            Button(pending.removal == .trashingFiles ? "移到废纸篓" : "移除", role: .destructive) {
                remove(pending.jobs, pending.removal, cleanup: pending.cleanup)
            }
        } message: { pending in
            Text(pending.message)
        }
        .alert(
            "有些文件没有移到废纸篓",
            isPresented: Binding(get: { !model.untrashedItems.isEmpty }, set: { if !$0 { model.untrashedItems = [] } }),
            presenting: model.untrashedItems
        ) { items in
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting(items) }
            Button("好", role: .cancel) {}
        } message: { items in
            Text("\(items.count) 项仍在原来的位置，可以在 Finder 中手动删除。")
        }
    }

    /// 菜单和 Delete 共用操作条件；移到废纸篓或含未完成任务时先确认。
    private func requestRemoval(of jobs: [Job], _ removal: JobRemoval) {
        let jobs = jobs.filter { model.canOperate(on: $0) }
        guard !jobs.isEmpty else { return }
        if removal == .trashingFiles || jobs.contains(where: \.isUnfinished) {
            pendingRemoval = PendingRemoval(jobs: jobs, removal: removal, cleanup: cleanupPlan(for: jobs))
        } else {
            remove(jobs, removal, cleanup: cleanupPlan(for: jobs))
        }
    }

    /// 发起移除时固定远端清理选择，设置变化不会扩大本次清理。
    private func cleanupPlan(for jobs: [Job]) -> [Job.ID: Bool] {
        Dictionary(uniqueKeysWithValues: jobs.map {
            ($0.id, $0.hasJobDirectory && !$0.isCleanedUp && model.settings.cleanupAfterDownload(for: $0.provider))
        })
    }

    /// 任务仍存在时切到其来源并清除筛选；已移除时只关闭过期提示。
    private func revealAddedJob(_ job: Job) {
        addedJobNotice = nil
        guard let currentJob = model.coordinator.jobs.first(where: { $0.id == job.id }) else { return }
        providerFilter = currentJob.provider
        category = .all
        searchText = ""
        selection = [currentJob.id]
    }

    private func remove(_ jobs: [Job], _ removal: JobRemoval, cleanup: [Job.ID: Bool]) {
        for job in jobs {
            selection.remove(job.id)
            model.remove(job, trashingFiles: removal == .trashingFiles, cleanupConfirmed: cleanup[job.id])
        }
    }

    #if DEBUG
    /// 演示模式：按启动参数选中分类和任务。
    private func showDemoSelection() async {
        guard DemoData.isEnabled else { return }
        while !model.coordinator.isStarted {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
        if let value = DemoData.category.flatMap(JobCategory.init(rawValue:)) {
            category = value
        }
        if let title = DemoData.selectedTitle, let job = model.coordinator.jobs.first(where: { $0.title == title }) {
            selection = [job.id]
            isInspectorPresented = true
        }
    }
    #endif
}

/// 等待确认的移除：要移除的任务和怎样处理已下载的文件。
private struct PendingRemoval {
    let jobs: [Job]
    let removal: JobRemoval
    let cleanup: [Job.ID: Bool]

    var title: String {
        let subject = jobs.count == 1 ? "移除“\(jobs[0].title)”" : "移除 \(jobs.count) 个任务"
        return removal == .trashingFiles ? subject + "并删除文件？" : subject + "？"
    }

    /// 按发起时固定的清理计划说明两家的移除范围。
    var message: String {
        var message: String
        switch removal {
        case .keepingFiles:
            message = "未完成的下载会取消，并删除已下载的部分。已完成的文件保留在本地。"
        case .trashingFiles:
            message = "已下载的文件会移到废纸篓。"
            if jobs.contains(where: \.isUnfinished) {
                message += "未完成的下载会取消，并删除已下载的部分。"
            }
        }
        for provider in Provider.allCases {
            let targets = jobs.filter { $0.provider == provider }
            guard !targets.isEmpty else { continue }
            let directories = targets.count { $0.hasJobDirectory && !$0.isCleanedUp && cleanup[$0.id] == true }
            message += "\n\(provider.title)：\(targets.count) 个任务；清理 \(directories) 个任务转存目录。"
        }
        return message
    }
}

/// 当前列表有可暂停任务时优先暂停，否则继续已暂停任务；无目标时禁用。
private struct PauseResumeAllButton: View {
    let jobs: [Job]
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.pausableJobs(in: jobs).isEmpty, !model.resumableJobs(in: jobs).isEmpty {
            Button {
                model.resumeAll(jobs)
            } label: {
                Label("继续当前列表", systemImage: "play.fill")
            }
            .help("继续当前列表的 \(model.resumableJobs(in: jobs).count) 个任务")
        } else {
            Button {
                model.pauseAll(jobs)
            } label: {
                Label("暂停当前列表", systemImage: "pause.fill")
            }
            .help("暂停当前列表的 \(model.pausableJobs(in: jobs).count) 个任务")
            .disabled(model.pausableJobs(in: jobs).isEmpty)
        }
    }
}

/// 仅操作当前网盘、分类及搜索结果中的上传任务。
private struct UploadPauseResumeAllButton: View {
    let jobs: [UploadJob]
    @Environment(AppModel.self) private var model

    var body: some View {
        let active = jobs.filter { !$0.phase.isTerminal && !$0.isPaused && !$0.cancellationRequested }
        let paused = jobs.filter { !$0.phase.isTerminal && $0.isPaused && !$0.cancellationRequested }
        let shouldResume = active.isEmpty
        let targets = shouldResume ? paused : active
        Button {
            Task {
                guard let coordinator = model.uploadCoordinator else { return }
                var problems: [String] = []
                for job in targets {
                    do {
                        if shouldResume { try await coordinator.resume(job.id) }
                        else { try await coordinator.pause(job.id) }
                    } catch { problems.append("\(job.title)：\(error.localizedDescription)") }
                }
                if !problems.isEmpty { model.uploadProblem = problems.joined(separator: "\n") }
            }
        } label: {
            Label(shouldResume ? "继续当前列表" : "暂停当前列表", systemImage: shouldResume ? "play.fill" : "pause.fill")
        }
        .disabled(targets.isEmpty)
        .help("\(shouldResume ? "继续" : "暂停")当前列表的 \(targets.count) 个上传任务")
    }
}

/// 汇总两家全部任务；筛选和搜索不改变全局进度、文件数及速度。
private struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @State private var showsStatistics = false

    var body: some View {
        let jobs = model.coordinator.jobs
        let activities = jobs.map { model.coordinator.activity(of: $0.id) }
        let progress = JobProgress(
            receivedBytes: activities.reduce(0) { $0 + $1.progress.receivedBytes },
            totalBytes: activities.reduce(0) { $0 + $1.progress.totalBytes },
            bytesPerSecond: activities.reduce(0) { $0 + $1.progress.bytesPerSecond })
        let totalFiles = jobs.reduce(0) { $0 + $1.files.count }
        let completedFiles = activities.reduce(0) { $0 + $1.completedFileCount }
        let preparing = jobs.count { $0.phase == .transferring }
        let summary = preparing == 0 ? progress.summary : [progress.sizeSummary, progress.speedText].compactMap { $0 }.joined(separator: " · ")
        if !jobs.isEmpty {
            HStack {
                Label("全部网盘", systemImage: "arrow.down")
                    .fixedSize()
                Text(summary)
                    .truncationMode(.tail)
                    .help(summary)
                Spacer(minLength: 0)
                Text("\(completedFiles)/\(totalFiles) 文件")
                    .fixedSize()
                Button {
                    showsStatistics.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .help("全部网盘下载统计")
                .accessibilityLabel("全部网盘下载统计")
                .popover(isPresented: $showsStatistics) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("全部网盘").font(.headline)
                        ProgressView(value: progress.fractionCompleted)
                        LabeledContent("已下载 / 已确定总大小", value: progress.sizeSummary)
                        LabeledContent("总速度", value: progress.speedText ?? "—")
                        LabeledContent("预计剩余时间", value: preparing == 0 ? progress.remainingTimeText ?? "—" : "等待文件准备完成")
                        LabeledContent("已完成文件", value: "\(completedFiles) / \(totalFiles)")
                        if preparing > 0 {
                            Text("\(preparing) 个任务正在准备，总大小和文件数尚未确定。")
                                .foregroundStyle(.secondary)
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
private struct TaskSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "搜索任务"
        field.setAccessibilityLabel("搜索任务")
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
    var focusTaskSearch: (() -> Void)? {
        get { self[TaskSearchFocusKey.self] }
        set { self[TaskSearchFocusKey.self] = newValue }
    }
}
