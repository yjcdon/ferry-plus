import AppKit
import FerryCore
import SwiftUI
import UniformTypeIdentifiers

extension UploadPhase {
    /// 上传发送结束仍有合并、回读和发布阶段，不能用字节进度替代完成状态。
    var displayName: String {
        switch self {
        case .preparing: "正在准备"
        case .queued: "等待上传"
        case .uploading: "正在上传"
        case .committing, .verifying, .publishing: "正在完成"
        case .completed: "已完成"
        case .skipped: "已跳过"
        case .failed: "上传失败"
        case .cancelled: "已取消"
        }
    }
}

extension UploadJob {
    /// 批次已有失败项且另有完成或跳过项时显示部分失败，执行阶段仍保留原 failed 语义。
    var hasPartialFailure: Bool {
        phase == .failed && failedCount > 0 && (completedCount > 0 || skippedCount > 0)
    }

    /// 批次状态在列表、明细及详情栏共用；单个文件仍展示自身阶段。
    var batchStatusText: String {
        let title = hasPartialFailure ? "部分失败" : phase.displayName
        return isPaused ? "已暂停 · \(title)" : title
    }
}

/// 上传的可用操作统一供列表、菜单、工具栏和详情使用，实际状态仍由 coordinator 持有。
enum UploadAction {
    case pause, resume, retry, cancel, remove, prioritize, reconcile
    func allows(_ job: UploadJob) -> Bool {
        switch self {
        case .pause: !job.phase.isTerminal && !job.isPaused && !job.cancellationRequested
        case .resume: job.isPaused && !job.phase.isTerminal && !job.cancellationRequested
        case .retry: job.phase == .failed && !job.cancellationRequested
        case .cancel, .prioritize: !job.phase.isTerminal && !job.cancellationRequested
        case .remove: job.phase.isTerminal || job.isPaused
        case .reconcile: job.phase == .failed || job.isPaused || job.cancellationRequested
        }
    }
}

struct UploadRow: View {
    let job: UploadJob
    var showsProvider = true
    let onAction: (TransferAction) -> Void
    let onLocateDuplicate: (UUID) -> Void
    let onInspect: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        TransferRowContent(title: job.title, systemImage: "arrow.up.doc",
                           provider: showsProvider ? job.account.provider : nil,
                           summary: summary) {
            if !job.phase.isTerminal {
                if isFinishing && !job.isPaused {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: Double(job.completedBytes), total: Double(max(1, job.totalBytes)))
                        .tint(job.isPaused ? .gray : nil)
                }
            }
        } actions: {
            if let action = primaryAction {
                Button { onAction(action) } label: { Label(action.title, systemImage: action.systemImage) }
                    .help(action.title).disabled(!action.allows(.upload(job), model: model))
            } else {
                Button("查看详情", systemImage: "info.circle", action: onInspect)
                    .help("查看详情")
            }
        } supplement: {
            if let originalID = job.duplicateOfJobID {
                HStack(spacing: 10) {
                    Text("已有相同内容的上传").foregroundStyle(.secondary)
                    Button("查看原任务") { onLocateDuplicate(originalID) }
                    Button("仍然上传") { onAction(.resume) }
                }
                .font(.caption).buttonStyle(.borderless)
            }
            if job.hasPartialFailure {
                Button("\(job.failedCount) 项失败，查看详情", action: onInspect)
                    .font(.caption).buttonStyle(.borderless)
            } else if let error = job.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error)
            }
        }
    }

    private var isFinishing: Bool { [.committing, .verifying, .publishing].contains(job.phase) }

    /// 主操作沿用现有能力；需要核对结果的任务仍可从菜单与详情进入专用动作。
    private var primaryAction: TransferAction? {
        if UploadAction.resume.allows(job) { return .resume }
        if UploadAction.retry.allows(job) { return .retry }
        if UploadAction.pause.allows(job) { return .pause }
        return nil
    }

    /// 发送速度只出现在真实上传阶段，收尾展示批次进度并由真实阶段决定完成。
    private var summary: String {
        var parts = [job.batchStatusText]
        parts.append(job.phase == .completed ? job.totalBytes.byteCount : "\(job.completedBytes.byteCount) / \(job.totalBytes.byteCount)")
        if job.phase == .uploading, !job.isPaused, let metrics = job.stageMetrics,
           metrics.phase == .uploading, metrics.averageBytesPerSecond > 0 {
            parts.append("\(Int64(metrics.averageBytesPerSecond.rounded()).byteCount)/s")
        }
        return parts.joined(separator: " · ")
    }
}

/// 每页最多 100 项；响应代次校验与 .task 取消共同阻止翻页后的迟到内容覆盖。
struct UploadInspector: View {
    let jobID: UUID
    let title: String
    let scope: TransferSelection
    let onPresentationChange: (Bool) -> Void
    @Environment(AppModel.self) private var model
    @State private var offset = 0
    @State private var generation = 0
    @State private var files: [UploadFile] = []
    @State private var loadedOffset: Int?
    @State private var isLoading = true
    @State private var error: String?
    @State private var relocation = RelocationFlow()
    @State private var location = LocationFlow()
    private let pageSize = 100

    private struct CloudRequest: Equatable {
        let id = UUID()
        let fileID: UUID
        let focus: RemoteReference?
        var directory: RemoteReference? = nil
    }

    private struct SourcePickerRequest: Equatable {
        let id = UUID()
        let fileID: UUID
    }

    private struct RelocationRequest: Equatable {
        let id = UUID()
        let fileID: UUID
        let url: URL
    }

    /// 源文件重定位与云端定位各自持有请求和结果。
    private struct RelocationFlow {
        var picker: SourcePickerRequest?
        var isPickerPresented = false
        var request: RelocationRequest?
        var error: String?
    }
    private struct LocationFlow {
        var request: CloudRequest?
        var error: String?
    }

    private struct PageRequest: Hashable {
        let offset: Int
        let generation: Int
        let count: Int
        let phase: UploadPhase?
        let completedCount: Int
        let failedCount: Int
        let skippedCount: Int
        let error: String?
    }
    private var job: UploadJob? { model.uploadJobs.first { $0.id == jobID } }
    private var isPresentingOperation: Bool {
        relocation.isPickerPresented || relocation.request != nil || location.request != nil
    }
    private var request: PageRequest {
        .init(offset: offset, generation: generation, count: job?.fileIDs.count ?? 0, phase: job?.phase,
              completedCount: job?.completedCount ?? 0,
              failedCount: job?.failedCount ?? 0, skippedCount: job?.skippedCount ?? 0, error: job?.error)
    }

    var body: some View {
        let page = request
        VStack(spacing: 0) {
            summary
            if let problem = location.error ?? relocation.error {
                HStack(alignment: .top, spacing: 8) {
                    Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("关闭") { location.error = nil; relocation.error = nil }
                }.padding(.horizontal).padding(.bottom, 12)
            }
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: page) { await load(page) }
        .task(id: relocation.request?.id) {
            guard let request = relocation.request else { return }
            await relocate(request)
        }
        .task(id: location.request?.id) {
            guard let request = location.request else { return }
            await openCloudDirectory(request)
        }
        .fileImporter(isPresented: $relocation.isPickerPresented, allowedContentTypes: [.item],
                      allowsMultipleSelection: false, onCompletion: { [picker = relocation.picker] result in
            guard let picker, relocation.picker?.id == picker.id else { return }
            relocation.picker = nil
            switch result {
            case .success(let urls):
                if let url = urls.first { relocation.request = .init(fileID: picker.fileID, url: url) }
            case .failure(let failure):
                if (failure as? CocoaError)?.code != .userCancelled { relocation.error = failure.localizedDescription }
            }
        }, onCancellation: { [picker = relocation.picker] in
            guard let picker, relocation.picker?.id == picker.id else { return }
            relocation.picker = nil; relocation.isPickerPresented = false
        })
        .onChange(of: job?.fileIDs.count) {
            let count = job?.fileIDs.count ?? 0
            if offset >= count { showPage(max(0, ((count - 1) / pageSize) * pageSize)) }
        }
        .onDisappear {
            relocation = .init(); location = .init()
            onPresentationChange(false)
        }
        .onChange(of: isPresentingOperation, initial: true) { _, presented in onPresentationChange(presented) }
    }

    /// 首屏聚焦任务结果与常用恢复操作，来源和数量合并展示。
    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(title).font(.headline).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let job, UploadAction.retry.allows(job) {
                    Button("重试失败项") {
                        scope.onAction(.retry, [.init(direction: .upload, id: job.id)])
                    }.disabled(scope.isBusy || !TransferAction.retry.allows(.upload(job), model: model))
                }
            }
            if let job {
                HStack {
                    Label(job.batchStatusText, systemImage: job.phase == .failed ? "exclamationmark.circle" :
                          job.phase == .completed ? "checkmark.circle" : "icloud.and.arrow.up")
                        .foregroundStyle(job.phase == .failed ? Color.orange : Color.secondary)
                    Spacer(minLength: 8)
                    Text("\(job.completedBytes.byteCount) / \(job.totalBytes.byteCount)")
                        .foregroundStyle(.secondary).monospacedDigit()
                }.font(.callout)
                if !job.phase.isTerminal {
                    if [.committing, .verifying, .publishing].contains(job.phase), !job.isPaused {
                        ProgressView().progressViewStyle(.linear)
                    } else {
                        ProgressView(value: Double(job.completedBytes), total: Double(max(1, job.totalBytes)))
                    }
                }
                if job.phase == .uploading, !job.isPaused,
                   let metrics = job.stageMetrics, metrics.phase == .uploading, metrics.averageBytesPerSecond > 0 {
                    HStack {
                        Text("\(Int64(metrics.averageBytesPerSecond.rounded()).byteCount)/s")
                        Spacer()
                        Text("当前文件剩余 " + Duration.seconds(metrics.estimatedRemainingSeconds)
                            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))
                    }.font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    ProviderIcon(provider: job.account.provider, size: 14)
                    Text(job.account.provider.title).lineLimit(1)
                }.font(.caption).foregroundStyle(.secondary)
                Text(countSummary(job)).font(.caption).foregroundStyle(.secondary)
                // 有文件失败时逐项展示原因；仅批次级问题留在摘要，避免重复整段错误。
                if job.failedCount == 0, let error = job.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }.padding()
    }

    private func countSummary(_ job: UploadJob) -> String {
        var parts = ["完成 \(job.completedCount) 项"]
        if job.failedCount > 0 { parts.append("失败 \(job.failedCount) 项") }
        if job.skippedCount > 0 { parts.append("跳过 \(job.skippedCount) 项") }
        return parts.joined(separator: " · ")
    }

    /// 单页显示总数；多页才提供翻页，刷新和任务命令沿用现有入口。
    private var footer: some View {
        HStack(spacing: 12) {
            let count = job?.fileIDs.count ?? 0
            Text(job == nil ? "任务已移除" : count > pageSize ? "第 \(offset / pageSize + 1) 页 · 共 \(count) 项" : "共 \(count) 项")
                .font(.caption).foregroundStyle(.secondary)
            if count > pageSize {
                Button { showPage(max(0, offset - pageSize)) } label: { Image(systemName: "chevron.left") }
                    .help("上一页").accessibilityLabel("上一页").disabled(offset == 0 || isLoading)
                Button { showPage(offset + pageSize) } label: { Image(systemName: "chevron.right") }
                    .help("下一页").accessibilityLabel("下一页").disabled(offset + pageSize >= count || isLoading)
            }
            Spacer(minLength: 0)
            Button { generation += 1 } label: { Image(systemName: "arrow.clockwise") }
                .help("刷新明细").accessibilityLabel("刷新明细").disabled(isLoading)
            Menu("操作") { TransferActionsMenu(scope: scope) }
                .menuStyle(.borderlessButton).fixedSize()
        }.controlSize(.small).padding(.horizontal).workspaceFooter()
    }

    /// 每项只展示名称、状态与必要错误，次要定位和源文件操作集中在该项菜单。
    private func fileRow(_ file: UploadFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: file.isDirectory ? "folder" : "doc")
                    .foregroundStyle(file.isDirectory ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(file.relativePath).lineLimit(2).truncationMode(.middle)
                        .help(file.relativePath).textSelection(.enabled)
                    HStack(spacing: 5) {
                        if file.phase == .failed { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                        Text(file.phase.displayName)
                        if !file.isDirectory { Text("· \(file.source.size.byteCount)") }
                    }.font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    fileLocationActions(for: file)
                    if canRelocate(file) {
                        Button("重新选择源文件") {
                            relocation.error = nil; relocation.picker = .init(fileID: file.id); relocation.isPickerPresented = true
                        }.disabled(relocation.request != nil)
                    }
                    if let error = file.error {
                        Button("复制错误") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(file.relativePath)：\(error)", forType: .string)
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("文件操作").accessibilityLabel("\(file.relativePath)的操作")
            }
            if let error = file.error {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(.leading, 24)
            }
            if relocation.request?.fileID == file.id {
                HStack { ProgressView().controlSize(.small); Text("正在检查文件").font(.caption) }
                    .padding(.leading, 24)
            }
        }.padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityActions { fileLocationActions(for: file) }
    }

    @ViewBuilder private var content: some View {
        if files.isEmpty {
            if isLoading { ProgressView("加载中") }
            else if let error {
                ContentUnavailableView {
                    Label("明细读取失败", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: { Button("重试") { generation += 1 } }
            } else { ContentUnavailableView("文件明细将显示在这里", systemImage: "doc") }
        } else {
            List(files) { file in fileRow(file) }
            .overlay(alignment: .topTrailing) {
                if isLoading { ProgressView().controlSize(.small).padding(8).accessibilityLabel("正在刷新明细") }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let error {
                    HStack(alignment: .top, spacing: 8) {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button("重试") { generation += 1 }.controlSize(.small).disabled(isLoading)
                    }
                    .padding(8)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
    }

    /// 定位菜单与辅助技术使用同一动作和能力条件，目标始终来自该文件记录。
    @ViewBuilder private func fileLocationActions(for file: UploadFile) -> some View {
        Button("打开云端所在目录", systemImage: "cloud") {
            location.request = .init(fileID: file.id, focus: file.isDirectory ? nil : file.remoteReference)
        }
        .disabled(file.remoteReference == nil || location.request != nil)
        Button("在 Finder 中显示源文件", systemImage: "folder") { revealSource(file) }
        if let replacement = file.replacement, let snapshot = replacement.snapshotObject {
            Button("打开旧版本备份", systemImage: "clock.arrow.circlepath") {
                location.request = .init(fileID: file.id, focus: snapshot, directory: replacement.parent)
            }.disabled(location.request != nil)
            Button("复制旧版本备份名称", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(replacement.snapshotName, forType: .string)
            }
        }
    }

    /// 换页时先清空上一页对象，避免新页标题下出现上一页的可操作条目。
    private func showPage(_ nextOffset: Int) {
        offset = nextOffset
        loadedOffset = nil; files = []
        isLoading = true; error = nil
    }

    /// 先关闭传输明细，再交给主文件页定位；查询及导航始终绑定原任务账号。
    private func openCloudDirectory(_ request: CloudRequest) async {
        location.error = nil
        defer { if location.request?.id == request.id { location.request = nil } }
        do {
            guard let sourceJob = job, let coordinator = model.uploadCoordinator else { throw UploadCoordinatorError.missingJob }
            guard model.accountKey(for: sourceJob.account.provider) == sourceJob.account else {
                throw UploadRecordError.invalid("请先登录任务所属的\(sourceJob.account.provider.title)账号，再打开云端目录。")
            }
            let directory: RemoteReference
            if let backupDirectory = request.directory {
                directory = backupDirectory
            } else {
                directory = try await coordinator.resultDirectory(jobID: jobID, fileID: request.fileID)
            }
            try Task.checkCancellation()
            guard location.request?.id == request.id else { return }
            guard job?.account == sourceJob.account,
                  model.accountKey(for: sourceJob.account.provider) == sourceJob.account else {
                throw UploadRecordError.invalid("账号或上传任务已变化，请重新定位。")
            }
            model.requestCloudLocation(account: sourceJob.account, directory: directory, focus: request.focus)
        } catch is CancellationError { }
        catch {
            guard location.request?.id == request.id, !Task.isCancelled else { return }
            location.error = error.localizedDescription
        }
    }

    /// 从保存的授权书签定位实际源文件；失效、已移走或无权限时显示原始完整路径与原因。
    private func revealSource(_ file: UploadFile) {
        var path = file.source.url.path
        do {
            let url = try file.source.bookmark.map { try UploadSource.resolve(bookmark: $0) } ?? file.source.url
            path = url.path
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard try url.checkResourceIsReachable() else { throw CocoaError(.fileReadNoSuchFile) }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { location.error = "\(path)\n\(error.localizedDescription)" }
    }

    /// 仅待发送且已有原始 SHA-256 的失败项可重新选源，校验云端内容时不再依赖本地文件。
    private func canRelocate(_ file: UploadFile) -> Bool {
        !file.isDirectory && file.phase == .failed && file.remoteReference == nil &&
        file.failedPhase.map { [.preparing, .queued, .uploading].contains($0) } == true &&
        !file.commits.contains { $0.status == .pending } &&
        file.expectation?.algorithm == .sha256 && file.expectation?.origin == .localOriginal &&
        job?.cancellationRequested == false
    }

    /// 选择仅变更本地定位；协调器停稳旧执行器并复核完整摘要，失败保持原记录。
    private func relocate(_ request: RelocationRequest) async {
        relocation.error = nil
        defer { if relocation.request?.id == request.id { relocation.request = nil } }
        do {
            guard let coordinator = model.uploadCoordinator else { throw UploadCoordinatorError.missingJob }
            try await coordinator.relocateSource(jobID: jobID, fileID: request.fileID, to: request.url)
            try Task.checkCancellation()
            guard relocation.request?.id == request.id else { return }
            generation += 1
        } catch is CancellationError { }
        catch {
            guard relocation.request?.id == request.id, !Task.isCancelled else { return }
            relocation.error = error.localizedDescription
        }
    }

    /// 摘要变化触发按页读取，不做定时轮询，也不让不可见明细常驻完整清单。
    private func load(_ page: PageRequest) async {
        guard page == request else { return }
        isLoading = true; error = nil
        if loadedOffset != page.offset {
            files = []
        }
        guard let coordinator = model.uploadCoordinator, let sourceJob = job else {
            isLoading = false; error = "上传任务读取失败，请重新打开。"
            return
        }
        do {
            let result = try await coordinator.files(jobID: jobID, offset: page.offset, limit: pageSize)
            try Task.checkCancellation()
            guard page == request, job?.account == sourceJob.account else { return }
            files = result; loadedOffset = page.offset; isLoading = false
        } catch {
            guard !Task.isCancelled, page == request else { return }
            self.error = error.localizedDescription; isLoading = false
        }
    }
}
