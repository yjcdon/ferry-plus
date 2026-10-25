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
        case .cancel: !job.phase.isTerminal && !job.cancellationRequested
        case .remove: job.phase.isTerminal || job.isPaused
        case .prioritize: !job.phase.isTerminal && !job.cancellationRequested
        case .reconcile: job.phase == .failed || job.isPaused || job.cancellationRequested
        }
    }
}

struct UploadRow: View {
    let job: UploadJob
    let onLocateDuplicate: (UUID) -> Void
    let onResumeDuplicate: () -> Void
    let onInspect: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.doc").font(.title2).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(job.title).font(.headline).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(job.batchStatusText)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let verification = job.verificationProgress {
                    ProgressView(value: Double(verification.verifiedBytes), total: Double(max(1, verification.totalBytes)))
                    HStack {
                        Text("回读校验 · \(verification.relativePath)").lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text("\(verification.verifiedBytes.fileSizeText) / \(verification.totalBytes.fileSizeText)")
                    }.font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView(value: Double(job.completedBytes), total: Double(max(1, job.totalBytes)))
                }
                HStack(spacing: 12) {
                    Text("\(job.account.provider.title) · \(job.accountName)")
                    Text("\(job.completedBytes.fileSizeText) / \(job.totalBytes.fileSizeText)")
                    Spacer(minLength: 0)
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("完成 \(job.completedCount) · 失败 \(job.failedCount) · 跳过 \(job.skippedCount)")
                    Spacer(minLength: 0)
                    if let metrics = job.stageMetrics {
                        Text(stageDescription(metrics)).lineLimit(1)
                            .help("当前文件：\(metrics.relativePath)。均速按本轮新增确认字节与经过时间计算。")
                    }
                }.font(.caption).foregroundStyle(.secondary)
                if let originalID = job.duplicateOfJobID {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("已有相同内容的上传，当前任务已暂停", systemImage: "doc.on.doc")
                        HStack(spacing: 10) {
                            Button("查看原任务") { onLocateDuplicate(originalID) }
                            Button("仍然上传", action: onResumeDuplicate)
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
                if let error = job.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Button("明细", action: onInspect)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 5)
    }
    /// 显示当前文件本轮的有效均速及估算，不把重试流量当成上传完成速度。
    private func stageDescription(_ metrics: UploadStageMetrics) -> String {
        let phase = metrics.phase == .verifying ? "回读均速" : "上传均速"
        let rate = Int64(metrics.averageBytesPerSecond.rounded()).fileSizeText
        let remaining = Duration.seconds(metrics.estimatedRemainingSeconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
        return "\(phase) \(rate)/s · 预计 \(remaining)"
    }

}

/// 每页最多 100 项；响应代次校验与 .task 取消共同阻止翻页后的迟到内容覆盖。
struct UploadFilesView: View {
    let jobID: UUID
    let title: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var offset = 0
    @State private var generation = 0
    @State private var files: [UploadFile] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var integrityDescriptions: [UUID: String] = [:]
    @State private var exportRequest: UUID?
    @State private var isPreparingExport = false
    @State private var exportDocument: IntegrityManifestDocument?
    @State private var isExportPresented = false
    @State private var exportError: String?
    @State private var relocationFileID: UUID?
    @State private var isRelocationPickerPresented = false
    @State private var relocationRequest: RelocationRequest?
    @State private var relocationError: String?
    @State private var locationError: String?
    @State private var cloudRequest: UUID?
    @State private var cloudLocation: CloudLocation?
    private let pageSize = 100

    private struct CloudLocation: Identifiable {
        let id = UUID()
        let account: AccountKey
        let directory: RemoteReference
    }

    private struct RelocationRequest: Equatable {
        let id = UUID()
        let fileID: UUID
        let url: URL
    }

    private struct PageRequest: Hashable {
        let offset: Int
        let generation: Int
        let integrityRevision: Int
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
        .init(offset: offset, generation: generation, integrityRevision: model.integrityRecordsRevision, count: job?.fileIDs.count ?? 0, phase: job?.phase,
              completedBytes: job?.completedBytes ?? 0, completedCount: job?.completedCount ?? 0,
              failedCount: job?.failedCount ?? 0, skippedCount: job?.skippedCount ?? 0, error: job?.error)
    }

    var body: some View {
        let page = request
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                if let job {
                    Text(job.batchStatusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isPreparingExport { ProgressView().controlSize(.small) }
                Button("导出已校验摘要…") {
                    exportError = nil; isPreparingExport = true; exportRequest = UUID()
                }.disabled(isPreparingExport || job == nil)
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
        .task(id: exportRequest) {
            guard let exportRequest else { return }
            await prepareExport(exportRequest)
        }
        .task(id: relocationRequest?.id) {
            guard let request = relocationRequest else { return }
            await relocate(request)
        }
        .task(id: cloudRequest) {
            guard let fileID = cloudRequest else { return }
            await openCloudDirectory(fileID: fileID)
        }
        .sheet(item: $cloudLocation) { location in
            NetdiskDownloadView(initialAccount: location.account, initialDirectory: location.directory)
                .environment(model)
        }
        .alert("无法定位文件", isPresented: Binding(
            get: { locationError != nil }, set: { if !$0 { locationError = nil } }
        )) { Button("好") { locationError = nil } } message: { Text(locationError ?? "") }
        .fileImporter(isPresented: $isRelocationPickerPresented, allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            guard let fileID = relocationFileID else { return }
            relocationFileID = nil
            switch result {
            case .success(let urls):
                if let url = urls.first { relocationRequest = .init(fileID: fileID, url: url) }
            case .failure(let failure):
                if (failure as? CocoaError)?.code != .userCancelled { relocationError = failure.localizedDescription }
            }
        }
        .alert("无法重新定位源文件", isPresented: Binding(
            get: { relocationError != nil }, set: { if !$0 { relocationError = nil } }
        )) { Button("好") { relocationError = nil } } message: { Text(relocationError ?? "") }
        .fileExporter(isPresented: $isExportPresented, document: exportDocument, contentType: .json,
                      defaultFilename: "Ferry-\(jobID.uuidString.prefix(8))-SHA256") { result in
            if case .failure(let failure) = result {
                if (failure as? CocoaError)?.code != .userCancelled { exportError = failure.localizedDescription }
            }
        }
        .alert("无法导出摘要清单", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) { Button("好") { exportError = nil } } message: { Text(exportError ?? "") }
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
                        Menu {
                            Button("打开云端所在目录", systemImage: "cloud") { cloudRequest = file.id }
                                .disabled(file.remoteReference == nil || cloudRequest != nil)
                            Button("在 Finder 中显示源文件", systemImage: "folder") { revealSource(file) }
                            if let replacement = file.replacement, replacement.snapshotObject != nil {
                                Button("复制旧版本备份名称", systemImage: "doc.on.doc") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(replacement.snapshotName, forType: .string)
                                }
                            }
                        } label: { Label("定位", systemImage: "location") }
                            .menuStyle(.borderlessButton).fixedSize().help("定位文件")
                    }
                    Text(integrityDescription(file)).font(.caption).foregroundStyle(.secondary)
                    if let replacement = file.replacement, replacement.snapshotObject != nil {
                        Text("已保留独立旧版本备份，可在云端所在目录下载恢复。")
                            .font(.caption).foregroundStyle(.secondary).help(replacement.snapshotName)
                    }
                    if canRelocate(file) {
                        HStack {
                            Button("重新定位源文件…") {
                                relocationFileID = file.id; isRelocationPickerPresented = true
                            }.controlSize(.small).disabled(relocationRequest != nil)
                            if relocationRequest?.fileID == file.id {
                                ProgressView().controlSize(.small)
                                Text("正在完整核对原始内容…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("源文件移动或授权失效时，可选择同内容文件；完整校验通过后沿用原上传会话。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if file.phase == .failed, file.remoteReference == nil, !file.isDirectory,
                              file.expectation == nil {
                        Text("尚无原始内容基准，请重新添加上传。").font(.caption).foregroundStyle(.secondary)
                    }
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

    /// 复用任务绑定账号的既有目录浏览入口，不把旧任务转到当前另一账号。
    private func openCloudDirectory(fileID: UUID) async {
        defer { cloudRequest = nil }
        do {
            guard let sourceJob = job, let coordinator = model.uploadCoordinator else { throw UploadCoordinatorError.missingJob }
            guard model.accountKey(for: sourceJob.account.provider) == sourceJob.account else {
                throw UploadRecordError.invalid("请先登录此任务的\(sourceJob.account.provider.title)账号“\(sourceJob.accountName)”再打开云端目录。")
            }
            let directory = try await coordinator.resultDirectory(jobID: jobID, fileID: fileID)
            try Task.checkCancellation()
            guard job?.account == sourceJob.account,
                  model.accountKey(for: sourceJob.account.provider) == sourceJob.account else {
                throw UploadRecordError.invalid("账号或上传任务已变化，请重新定位。")
            }
            cloudLocation = .init(account: sourceJob.account, directory: directory)
        } catch is CancellationError { }
        catch { locationError = error.localizedDescription }
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
        } catch { locationError = "\(path)\n\(error.localizedDescription)" }
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
        defer { if relocationRequest?.id == request.id { relocationRequest = nil } }
        do {
            guard let coordinator = model.uploadCoordinator else { throw UploadCoordinatorError.missingJob }
            try await coordinator.relocateSource(jobID: jobID, fileID: request.fileID, to: request.url)
            try Task.checkCancellation()
            generation += 1
        } catch is CancellationError { }
        catch { relocationError = error.localizedDescription }
    }

    private func integrityDescription(_ file: UploadFile) -> String {
        if file.isDirectory { return "目录项目，不进行文件内容校验" }
        if file.integrityRecordID != nil { return integrityDescriptions[file.id] ?? "正在核对校验记录…" }
        return file.phase == .completed ? "已完成，未关联校验记录" : "尚未生成校验记录"
    }

    private struct ExportFile {
        let path: String
        let remoteName: String
        let size: Int64
        let digest: String
    }

    /// 分页只保留目录命名和摘要，不保留完整 UploadFile／分片；每条基准来自独立校验库。
    private func prepareExport(_ request: UUID) async {
        defer { isPreparingExport = false }
        do {
            guard let coordinator = model.uploadCoordinator, let sourceJob = job else { throw UploadCoordinatorError.missingJob }
            guard sourceJob.fileIDs.count <= IntegrityManifest.maximumEntries else {
                throw UploadRecordError.invalid("一次最多导出 10000 个清单项目，请拆分上传批次")
            }
            let store = model.integrityStore
            let revision = model.integrityRecordsRevision
            var directoryNames: [String: String] = [:]
            var verified: [ExportFile] = []
            for offset in stride(from: 0, to: sourceJob.fileIDs.count, by: pageSize) {
                try Task.checkCancellation()
                let page = try await coordinator.files(jobID: jobID, offset: offset, limit: pageSize)
                let expectedIDs = Array(sourceJob.fileIDs.dropFirst(offset).prefix(pageSize))
                guard page.map(\.id) == expectedIDs else { throw UploadRecordError.invalid("上传清单已变化，请重新导出") }
                for file in page {
                    try Task.checkCancellation()
                    if file.isDirectory {
                        if let name = file.remoteName { directoryNames[file.relativePath] = name }
                        continue
                    }
                    guard file.phase == .completed, let id = file.integrityRecordID else { continue }
                    let record: IntegrityRecord
                    do { record = try await store.load(id: id) }
                    catch { if Self.isMissingRecord(error) { continue }; throw error }
                    guard record.status == .verified, record.account == sourceJob.account,
                          record.uploadFileID == file.id, record.reference == file.remoteReference,
                          let expectation = record.expectation, expectation.algorithm == .sha256,
                          expectation.origin == .localOriginal, expectation.size == file.source.size,
                          file.expectation?.algorithm == .sha256, file.expectation?.digest == expectation.digest,
                          let name = file.remoteName else {
                        throw UploadRecordError.invalid("文件缺少可确认归属的已验证原始摘要：\(file.relativePath)")
                    }
                    verified.append(.init(path: file.relativePath, remoteName: name, size: expectation.size, digest: expectation.digest))
                }
            }
            guard !verified.isEmpty else { throw UploadRecordError.invalid("没有可导出的已校验文件；目录及缺少校验记录的文件不会导出") }
            let entries = try verified.map { file -> IntegrityManifestEntry in
                let components = file.path.split(separator: "/").map(String.init)
                var remote: [String] = []
                for index in 0..<(components.count - 1) {
                    let sourcePath = components.prefix(index + 1).joined(separator: "/")
                    guard let name = directoryNames[sourcePath] else {
                        throw UploadRecordError.invalid("无法确认已上传目录名称：\(sourcePath)")
                    }
                    remote.append(name)
                }
                remote.append(file.remoteName)
                return try IntegrityManifestEntry(relativePath: remote.joined(separator: "/"), size: file.size,
                                                   algorithm: .sha256, digest: file.digest)
            }
            let manifest = try IntegrityManifest(entries: entries)
            let document = try IntegrityManifestDocument(manifest: manifest)
            try Task.checkCancellation()
            guard exportRequest == request, job?.account == sourceJob.account else { throw UploadCoordinatorError.missingJob }
            guard model.integrityRecordsRevision == revision else { throw UploadRecordError.invalid("校验记录已变化，请重新导出") }
            exportDocument = document; isExportPresented = true
        } catch {
            guard !Task.isCancelled, exportRequest == request else { return }
            exportError = error.localizedDescription
        }
    }

    /// 只有明确不存在的文件才表示已清理；损坏 JSON、未知版本与权限错误必须继续显示错误。
    private static func isMissingRecord(_ error: any Error) -> Bool {
        (error as? CocoaError)?.code == .fileReadNoSuchFile
    }

    /// 摘要变化触发按页读取，不做定时轮询，也不让不可见明细常驻完整清单。
    private func load(_ page: PageRequest) async {
        guard page == request else { return }
        isLoading = true; error = nil; files = []; integrityDescriptions = [:]
        guard let coordinator = model.uploadCoordinator, let sourceJob = job else {
            isLoading = false; error = "上传任务或服务尚不可用。"
            return
        }
        do {
            let result = try await coordinator.files(jobID: jobID, offset: page.offset, limit: pageSize)
            var descriptions: [UUID: String] = [:]
            for file in result where !file.isDirectory {
                try Task.checkCancellation()
                guard let id = file.integrityRecordID else { continue }
                do {
                    let record = try await model.integrityStore.load(id: id)
                    guard record.account == sourceJob.account, record.uploadFileID == file.id,
                          record.reference == file.remoteReference,
                          let expected = file.expectation, let evidence = record.expectation,
                          evidence.algorithm == .sha256, evidence.algorithm == expected.algorithm,
                          evidence.digest == expected.digest, evidence.origin == expected.origin,
                          evidence.size == file.source.size else {
                        throw UploadRecordError.invalid("校验记录与上传文件归属不一致：\(file.relativePath)")
                    }
                    descriptions[file.id] = switch record.status {
                    case .verified: "SHA-256 内容校验通过"
                    case .mismatch: "内容校验失败"
                    case .pending: "校验尚未完成"
                    case .unavailable: "未验证源文件内容"
                    }
                } catch {
                    guard Self.isMissingRecord(error) else { throw error }
                    descriptions[file.id] = "校验记录已清理"
                }
            }
            try Task.checkCancellation()
            guard page == request, job?.account == sourceJob.account else { return }
            integrityDescriptions = descriptions; files = result; isLoading = false
        } catch {
            guard !Task.isCancelled, page == request else { return }
            self.error = error.localizedDescription; isLoading = false
        }
    }
}
