import AppKit
import FerryCore
import SwiftUI

extension UploadPhase {
    /// 上传发送结束仍有合并、回读和发布阶段，不能用字节进度替代完成状态。
    var displayName: String {
        switch self {
        case .preparing: "正在准备"
        case .queued: "等待上传"
        case .uploading: "正在上传"
        case .committing: "正在核对合并结果"
        case .verifying: "正在校验云端内容"
        case .publishing: "正在发布文件"
        case .completed: "已完成"
        case .skipped: "已跳过"
        case .failed: "上传失败"
        case .cancelled: "已取消"
        }
    }
}

/// 仅接收主窗口当前筛选后的上传批次；命令冻结当前可见项，绝不查询隐藏任务作为操作范围。
struct UploadListView: View {
    let jobs: [UploadJob]
    @Environment(AppModel.self) private var model
    @State private var selection: Set<UUID> = []
    @State private var command: Command?
    @State private var removal: [UUID] = []
    @State private var operationError: String?
    @State private var detail: DetailRequest?

    private enum Action: String {
        case pause = "暂停", resume = "继续", retry = "重试失败项", cancel = "取消上传"
        case remove = "移除记录", prioritize = "优先上传", reconcile = "核对远端结果"

        func allows(_ job: UploadJob) -> Bool {
            switch self {
            case .pause: !job.phase.isTerminal && !job.isPaused && !job.cancellationRequested
            case .resume: job.isPaused && !job.phase.isTerminal && !job.cancellationRequested
            case .retry: job.phase == .failed && !job.cancellationRequested
            case .cancel: !job.phase.isTerminal && !job.cancellationRequested
            case .remove: job.phase.isTerminal || job.isPaused
            case .prioritize: !job.phase.isTerminal && !job.cancellationRequested
            case .reconcile: job.phase == .failed || job.isPaused || job.cancellationRequested
            }
        }
    }
    private struct Command: Identifiable {
        let id = UUID()
        let action: Action
        let jobs: [UploadJob]
    }
    private struct DetailRequest: Identifiable {
        let id: UUID
        let title: String
    }

    var body: some View {
        VStack(spacing: 0) {
            if jobs.isEmpty {
                ContentUnavailableView("没有上传任务", systemImage: "tray.and.arrow.up")
            } else {
                controls.padding(.horizontal).padding(.vertical, 8)
                Divider()
                List(jobs, selection: $selection) { job in
                    UploadRow(job: job)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    actions(for: jobs.filter { ids.contains($0.id) })
                } primaryAction: { ids in
                    showDetails(jobs.filter { ids.contains($0.id) })
                }
                .onDeleteCommand {
                    requestRemoval(jobs.filter { selection.contains($0.id) })
                }
            }
        }
        .onChange(of: jobs.map(\.id)) { selection.formIntersection(jobs.map(\.id)) }
        .task(id: command?.id) {
            guard let command else { return }
            await perform(command)
        }
        .confirmationDialog("移除 \(removal.count) 项上传记录？", isPresented: Binding(
            get: { !removal.isEmpty }, set: { if !$0 { removal = [] } }
        ), titleVisibility: .visible) {
            Button("移除记录", role: .destructive) {
                let ids = Set(removal)
                removal = []
                start(.remove, jobs: jobs.filter { ids.contains($0.id) })
            }
        } message: {
            Text("仅移除本地任务记录，保留本地源文件、已上传的云端文件和独立校验记录。未核对的远端操作会阻止移除。")
        }
        .alert("上传操作未完成", isPresented: Binding(
            get: { operationError != nil }, set: { if !$0 { operationError = nil } }
        )) { Button("好") { operationError = nil } } message: { Text(operationError ?? "") }
        .sheet(item: $detail) { item in
            UploadFilesView(jobID: item.id, title: item.title)
                .environment(model)
        }
    }

    private var targets: [UploadJob] {
        selection.isEmpty ? jobs : jobs.filter { selection.contains($0.id) }
    }
    private var isBusy: Bool { command != nil }

    private var controls: some View {
        HStack {
            Text(selection.isEmpty ? "当前显示 \(jobs.count) 项" : "已选 \(targets.count) 项")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
            Button("暂停") { start(.pause, jobs: targets) }
                .disabled(isBusy || !targets.contains(where: Action.pause.allows))
            Button("继续") { start(.resume, jobs: targets) }
                .disabled(isBusy || !targets.contains(where: Action.resume.allows))
            Menu("更多") { actions(for: targets) }
                .disabled(isBusy || targets.isEmpty)
        }
    }

    @ViewBuilder
    private func actions(for targets: [UploadJob]) -> some View {
        ForEach([Action.pause, .resume, .retry, .prioritize, .reconcile, .cancel], id: \.self) { action in
            if targets.contains(where: action.allows) {
                Button(action.rawValue) { start(action, jobs: targets) }.disabled(isBusy)
            }
        }
        if !targets.isEmpty {
            Divider()
            Button("查看明细…") { showDetails(targets) }.disabled(targets.count != 1)
            Button("复制错误") { copyErrors(targets) }.disabled(!targets.contains { $0.error != nil })
            if targets.contains(where: Action.remove.allows) {
                Divider()
                Button("移除记录…", role: .destructive) { requestRemoval(targets) }.disabled(isBusy)
            }
        }
    }

    /// 所有入口都再次与当前可见列表相交，右键、删除键和确认弹窗不扩大操作范围。
    private func start(_ action: Action, jobs requested: [UploadJob]) {
        guard !isBusy else { return }
        let ids = Set(requested.map(\.id))
        let targets = jobs.filter { ids.contains($0.id) && action.allows($0) }
        guard !targets.isEmpty else { return }
        command = .init(action: action, jobs: targets)
    }

    private func requestRemoval(_ targets: [UploadJob]) {
        guard !isBusy else { return }
        let visible = Set(jobs.map(\.id))
        removal = targets.filter { visible.contains($0.id) && Action.remove.allows($0) }.map(\.id)
    }

    /// 一个批次失败不阻断其他独立选中项，最后集中展示具体任务错误；取消立即停止后续命令。
    private func perform(_ request: Command) async {
        defer { command = nil }
        guard let coordinator = model.uploadCoordinator else {
            operationError = "上传服务尚未就绪。"
            return
        }
        var failures: [String] = []
        for job in request.jobs {
            if Task.isCancelled { return }
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

    private func showDetails(_ targets: [UploadJob]) {
        guard targets.count == 1, let job = targets.first, jobs.contains(where: { $0.id == job.id }) else { return }
        detail = .init(id: job.id, title: job.title)
    }
    private func copyErrors(_ targets: [UploadJob]) {
        let visible = Set(jobs.map(\.id))
        let text = targets.filter { visible.contains($0.id) }.compactMap { job in
            job.error.map { "\(job.title)：\($0)" }
        }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct UploadRow: View {
    let job: UploadJob
    @State private var isShowingDetails = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.doc").font(.title2).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(job.title).font(.headline).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(job.isPaused ? "已暂停 · \(job.phase.displayName)" : job.phase.displayName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(job.completedBytes), total: Double(max(1, job.totalBytes)))
                HStack(spacing: 12) {
                    Text("\(job.account.provider.title) · \(job.accountName)")
                    Text("\(ByteCountFormatter.string(fromByteCount: job.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file))")
                    Spacer(minLength: 0)
                }
                .font(.caption).foregroundStyle(.secondary)
                Text("完成 \(job.completedCount) · 失败 \(job.failedCount) · 跳过 \(job.skippedCount)")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = job.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                }
            }
            Button("明细") { isShowingDetails = true }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 5)
        .sheet(isPresented: $isShowingDetails) {
            UploadFilesView(jobID: job.id, title: job.title)
        }
    }
}

/// 每页最多 100 项；响应代次校验与 .task 取消共同阻止翻页后的迟到内容覆盖。
private struct UploadFilesView: View {
    let jobID: UUID
    let title: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var offset = 0
    @State private var generation = 0
    @State private var files: [UploadFile] = []
    @State private var isLoading = true
    @State private var error: String?
    private let pageSize = 100

    private struct PageRequest: Hashable {
        let offset: Int
        let generation: Int
        let count: Int
        let phase: UploadPhase?
        let completedBytes: Int64
        let completedCount: Int
        let failedCount: Int
        let skippedCount: Int
        let error: String?
    }
    private var job: UploadJob? { model.uploadJobs.first { $0.id == jobID } }
    private var request: PageRequest {
        .init(offset: offset, generation: generation, count: job?.fileIDs.count ?? 0, phase: job?.phase,
              completedBytes: job?.completedBytes ?? 0, completedCount: job?.completedCount ?? 0,
              failedCount: job?.failedCount ?? 0, skippedCount: job?.skippedCount ?? 0, error: job?.error)
    }

    var body: some View {
        let page = request
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { generation += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新明细").disabled(isLoading)
            }.padding()
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text(job == nil ? "任务已移除" : "第 \(offset / pageSize + 1) 页 · 共 \(job?.fileIDs.count ?? 0) 项")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("上一页") { offset = max(0, offset - pageSize) }.disabled(offset == 0 || isLoading)
                Button("下一页") { offset += pageSize }.disabled(offset + pageSize >= (job?.fileIDs.count ?? 0) || isLoading)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 420, idealHeight: 520)
        .task(id: page) { await load(page) }
        .onChange(of: job?.fileIDs.count) {
            let count = job?.fileIDs.count ?? 0
            if offset >= count { offset = max(0, ((count - 1) / pageSize) * pageSize) }
        }
    }

    @ViewBuilder private var content: some View {
        if isLoading { ProgressView("正在读取明细…") }
        else if let error {
            ContentUnavailableView {
                Label("无法读取明细", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: { Button("重试") { generation += 1 } }
        } else if files.isEmpty { ContentUnavailableView("没有文件明细", systemImage: "doc") }
        else {
            List(files) { file in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label(file.relativePath, systemImage: file.isDirectory ? "folder" : "doc")
                            .lineLimit(1).truncationMode(.middle).help(file.relativePath)
                        Spacer()
                        Text(file.phase.displayName).foregroundStyle(.secondary)
                    }
                    Text(integrityDescription(file)).font(.caption).foregroundStyle(.secondary)
                    if let error = file.error {
                        HStack(alignment: .top) {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            Spacer()
                            Button("复制错误") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("\(file.relativePath)：\(error)", forType: .string)
                            }.controlSize(.small)
                        }
                    }
                }.padding(.vertical, 3)
            }
        }
    }

    private func integrityDescription(_ file: UploadFile) -> String {
        if file.isDirectory { return "目录项目，不进行文件内容校验" }
        if let id = file.integrityRecordID { return "已关联校验记录 · \(id.uuidString)" }
        return file.phase == .completed ? "已完成，未关联校验记录" : "尚未生成校验记录"
    }

    /// 摘要变化触发按页读取，不做定时轮询，也不让不可见明细常驻完整清单。
    private func load(_ page: PageRequest) async {
        guard page == request else { return }
        isLoading = true; error = nil; files = []
        guard let coordinator = model.uploadCoordinator, job != nil else {
            isLoading = false; error = "上传任务或服务尚不可用。"
            return
        }
        do {
            let result = try await coordinator.files(jobID: jobID, offset: page.offset, limit: pageSize)
            try Task.checkCancellation()
            guard page == request else { return }
            files = result; isLoading = false
        } catch {
            guard !Task.isCancelled, page == request else { return }
            self.error = error.localizedDescription; isLoading = false
        }
    }
}
