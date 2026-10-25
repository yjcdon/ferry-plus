import Foundation
import CryptoKit
import DownloadKit
import QuarkKit

public enum UploadCoordinatorError: Error, LocalizedError, Sendable {
    case missingJob, missingSelections, scanIssue(String), missingParent(String), unsafeReplacement
    case unconfirmedCommit, rejectedCommit(String), persistence(String), mismatch, busy
    public var errorDescription: String? {
        switch self {
        case .missingJob: "上传任务不存在"
        case .missingSelections: "上传检查点缺少完整源选择，请重新添加任务"
        case .scanIssue(let message): "上传源扫描未完成：\(message)"
        case .missingParent(let path): "上传父目录尚未成功创建：\(path)"
        case .unsafeReplacement: "当前网盘或项目类型不支持安全覆盖，原有内容未改动"
        case .unconfirmedCommit: "远端提交结果仍未核对，已保留记录；不能重复提交或移除"
        case .rejectedCommit(let message): "远端提交已拒绝：\(message)"
        case .persistence(let message): "上传检查点保存失败：\(message)"
        case .mismatch: "上传文件回读内容与原始 SHA-256 不一致"
        case .busy: "上传任务仍在收尾，请稍后重试"
        }
    }
}

/// 上传批次及文件检查点的唯一执行写入方；摘要列表常驻，文件与回执按需加载。
public actor UploadCoordinator {
    private struct Worker { let token: UUID; let task: Task<Void, Never> }
    private let store: UploadStore
    private let integrityStore: IntegrityStore
    private let budget: TransferBudget
    private var integrity: IntegrityService
    private let secrets: (any UploadSecretStorage)?
    private var maximumConcurrentJobs: Int
    private var maximumConcurrentParts: Int
    private let environment: @Sendable (AccountKey) async throws -> UploadEnvironment
    private let onBatchFinished: (@Sendable (UploadJob) async -> Void)?
    private var jobs: [UUID: UploadJob] = [:]
    private var workers: [UUID: Worker] = [:]
    /// 每个批次最多一个当前回读文件，只用于快照展示，不保存或恢复增量摘要。
    private var verificationProgress: [UUID: UploadVerificationProgress] = [:]
    private struct StageSample {
        let fileID: UUID
        let relativePath: String
        let phase: UploadPhase
        let startedAt: ContinuousClock.Instant
        let initialBytes: Int64
        var currentBytes: Int64
        let totalBytes: Int64
    }
    private var stageSamples: [UUID: StageSample] = [:]
    /// 单文件重新定位的完整复核及持久化任务，同样纳入睡眠／退出收尾和资源活动。
    private var relocations: [UUID: Task<Void, Error>] = [:]
    private var observers: [UUID: AsyncStream<[UploadJob]>.Continuation] = [:]
    private var activityObservers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var lastActivity = false
    private var globallySuspended = false
    private var suspendedProviders: Set<Provider> = []
    private var stopping: Set<UUID> = []
    private var isRestoring = false
    private var closed = false

    public init(store: UploadStore, integrityStore: IntegrityStore, budget: TransferBudget,
                integrity: IntegrityService, secrets: (any UploadSecretStorage)? = nil, maximumConcurrentJobs: Int = 1,
                maximumConcurrentParts: Int = 1,
                onBatchFinished: (@Sendable (UploadJob) async -> Void)? = nil,
                environment: @escaping @Sendable (AccountKey) async throws -> UploadEnvironment) throws {
        guard (1...4).contains(maximumConcurrentJobs) else { throw UploadRecordError.invalid("同时上传批次数必须为 1～4") }
        guard (1...4).contains(maximumConcurrentParts) else { throw UploadRecordError.invalid("单文件上传并发数必须为 1～4") }
        self.store = store; self.integrityStore = integrityStore; self.budget = budget; self.integrity = integrity
        self.secrets = secrets
        self.maximumConcurrentJobs = maximumConcurrentJobs; self.maximumConcurrentParts = maximumConcurrentParts
        self.environment = environment
        self.onBatchFinished = onBatchFinished
    }

    deinit {
        for worker in workers.values { worker.task.cancel() }
        for relocation in relocations.values { relocation.cancel() }
        for observer in observers.values { observer.finish() }
        for observer in activityObservers.values { observer.finish() }
    }

    /// 先逐文件重建已落盘聚合，再发布和调度；保留暂停意图、阶段及远端回执。
    /// 文件读取或聚合保存失败时明确中止恢复，不以缺失记录覆盖进度，也不启动 worker。
    public func restore() async throws {
        guard !isRestoring, workers.isEmpty, jobs.isEmpty else { throw UploadCoordinatorError.busy }
        isRestoring = true
        defer { isRestoring = false }
        let restored = try await store.loadJobs()
        var recovered: [UUID: UploadJob] = [:]
        for job in restored {
            let rebuilt = try await aggregate(job)
            if rebuilt != job { try await store.saveJob(rebuilt) }
            recovered[job.id] = rebuilt
        }
        jobs = recovered
        emit(); schedule()
    }

    /// 在扫描前保存所有选择及账号，整批清单完成后才能产生远端副作用。
    @discardableResult
    public func add(account: AccountKey, accountName: String, destination: RemoteReference,
                    selections: [UploadSelection], conflictPolicy: UploadConflictPolicy = .keepBoth) async throws -> UUID {
        guard !isRestoring else { throw UploadCoordinatorError.busy }
        guard !closed, !selections.isEmpty else { throw UploadCoordinatorError.missingSelections }
        let names = selections.map { $0.url.lastPathComponent }
        var job = UploadJob(account: account, accountName: accountName, title: names.count == 1 ? names[0] : "\(names[0]) 等 \(names.count) 项",
                            destination: destination, conflictPolicy: conflictPolicy)
        job.selections = selections
        job.duplicateCandidateIDs = jobs.values.filter {
            $0.account == account && $0.destination == destination && !$0.phase.isTerminal &&
            !$0.cancellationRequested && $0.duplicateOfJobID == nil
        }.map(\.id)
        try await store.saveJob(job)
        jobs[job.id] = job; emit(); schedule()
        return job.id
    }

    /// 摘要来自同一批次状态，不复制一份 UI 执行模型。
    public func snapshots() -> [UploadJob] {
        jobs.values.sorted { $0.createdAt < $1.createdAt }.map { job in
            var snapshot = job
            snapshot.verificationProgress = verificationProgress[job.id]
            snapshot.stageMetrics = stageMetrics(for: job)
            return snapshot
        }
    }

    /// 明细分页读取，避免展示列表时把整棵目录及所有分片常驻内存。
    public func files(jobID: UUID, offset: Int = 0, limit: Int = 100) async throws -> [UploadFile] {
        guard let job = jobs[jobID] else { throw UploadCoordinatorError.missingJob }
        guard offset >= 0, (1...500).contains(limit) else { throw UploadRecordError.invalid("上传明细分页无效") }
        var result: [UploadFile] = []
        for id in job.fileIDs.dropFirst(offset).prefix(limit) { result.append(try await store.loadFile(id: id, in: job)) }
        return result
    }

    /// 定位已确认产物所在的准确云端目录；嵌套文件只读取已发布父目录，不按同名条目猜测。
    public func resultDirectory(jobID: UUID, fileID: UUID) async throws -> RemoteReference {
        guard let job = jobs[jobID], job.fileIDs.contains(fileID) else { throw UploadCoordinatorError.missingJob }
        let file = try await store.loadFile(id: fileID, in: job)
        guard let result = file.remoteReference else { throw UploadRecordError.invalid("此项目尚无已确认的云端结果") }
        if file.isDirectory { return result }
        let parentPath = file.relativePath.split(separator: "/").dropLast().joined(separator: "/")
        if parentPath.isEmpty { return job.destination }
        let parentID = stableID(jobID: jobID, relativePath: parentPath)
        let parent = try await store.loadFile(id: parentID, in: job)
        guard parent.isDirectory, let directory = parent.remoteReference else {
            throw UploadRecordError.invalid("上传父目录尚无已确认的云端身份：\(parentPath)")
        }
        return directory
    }

    /// 仅变化时发布最新摘要；取消订阅不保留 coordinator。
    public func updates() -> AsyncStream<[UploadJob]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation; continuation.yield(snapshots())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    /// 执行活动以实际 worker 为准，包括扫描、发送、提交与校验等待；排队和手动暂停不产生活动。
    public func isExecuting() -> Bool { !workers.isEmpty || !relocations.isEmpty }

    /// 仅 worker 活动变化时发布，供应用合并下载活动管理防休眠，无常驻轮询。
    public func activityUpdates() -> AsyncStream<Bool> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            activityObservers[id] = continuation; continuation.yield(!workers.isEmpty || !relocations.isEmpty)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeActivityObserver(id) } }
        }
    }

    /// 运行时阻断先于取消；等待匹配 worker 收尾，不改变用户暂停意图，也不停止另一家网盘。
    public func suspendExecution(for provider: Provider? = nil) async {
        if let provider { suspendedProviders.insert(provider) }
        else { globallySuspended = true }
        let tasks = workers.compactMap { id, worker -> Task<Void, Never>? in
            provider == nil || jobs[id]?.account.provider == provider ? worker.task : nil
        }
        let relocating = relocations.compactMap { id, task -> Task<Void, Error>? in
            provider == nil || jobs[id]?.account.provider == provider ? task : nil
        }
        for task in tasks { task.cancel() }
        for task in relocating { task.cancel() }
        for task in tasks { await task.value }
        for task in relocating { _ = try? await task.value }
        publishActivity()
    }

    /// 全局与各网盘阻断独立保留；关闭后不放行，不覆盖手动暂停或取消状态。
    public func resumeExecution(for provider: Provider? = nil) {
        guard !closed else { return }
        if let provider { suspendedProviders.remove(provider) }
        else { globallySuspended = false }
        schedule()
    }

    /// 代理切换必须先全局停稳，才能替换持有旧网络会话的校验服务。
    public func replaceIntegrityService(_ service: IntegrityService) throws {
        guard !closed, globallySuspended, workers.isEmpty, relocations.isEmpty else { throw UploadCoordinatorError.busy }
        integrity = service
    }

    /// 暂停先停止旧 worker，再返回；已收到的分片回执仍优先保存。
    public func pause(_ id: UUID) async throws {
        guard jobs[id] != nil else { throw UploadCoordinatorError.missingJob }
        guard !stopping.contains(id) else { throw UploadCoordinatorError.busy }
        jobs[id]!.isPaused = true
        let task = workers[id]?.task; task?.cancel()
        var saveError: (any Error)?
        do { try await persistJob(id) } catch { saveError = error }
        await task?.value
        if let saveError { throw saveError }
    }

    /// 继续只启动一个新 worker；重复任务的继续表示用户明确允许再次上传，持久化后不再自阻断。
    public func resume(_ id: UUID) async throws {
        guard let job = jobs[id] else { throw UploadCoordinatorError.missingJob }
        guard workers[id] == nil, !stopping.contains(id), !job.cancellationRequested else { throw UploadCoordinatorError.busy }
        jobs[id]!.isPaused = false
        jobs[id]!.duplicateOfJobID = nil
        try await persistJob(id); schedule()
    }

    /// 失败项恢复原失败阶段；未决合并进入查询，不重新提交。
    public func retry(_ id: UUID) async throws {
        guard let job = jobs[id] else { throw UploadCoordinatorError.missingJob }
        guard workers[id] == nil, !stopping.contains(id), !job.cancellationRequested else { throw UploadCoordinatorError.busy }
        stopping.insert(id)
        defer { stopping.remove(id); schedule() }
        for fileID in job.fileIDs {
            var file = try await store.loadFile(id: fileID, in: job)
            if file.phase == .failed {
                file.phase = file.failedPhase ?? .preparing; file.failedPhase = nil; file.error = nil
                try await saveFile(file)
            }
        }
        jobs[id]!.phase = job.scanCompletedAt == nil ? .preparing : .queued
        jobs[id]!.isPaused = false; jobs[id]!.error = nil
        try await rebuildAggregate(id)
    }

    /// 原文件移动或授权失效时，先停稳批次，再完整核对新文件；不改变账号、上传会话及分片回执。
    /// 只有已有原始 SHA-256 的失败文件可重新定位；目录映射或尚无原始摘要的选择须重新添加。
    public func relocateSource(jobID: UUID, fileID: UUID, to url: URL) async throws {
        guard let job = jobs[jobID], job.fileIDs.contains(fileID) else { throw UploadCoordinatorError.missingJob }
        guard !closed, !globallySuspended, !suspendedProviders.contains(job.account.provider),
              !job.cancellationRequested, !stopping.contains(jobID) else { throw UploadCoordinatorError.busy }
        guard url.isFileURL else { throw UploadSourceError.nonFileURL }
        stopping.insert(jobID)
        let previous = workers[jobID]?.task
        let operation = Task<Void, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.runRelocation(jobID: jobID, fileID: fileID, to: url, previous: previous)
        }
        relocations[jobID] = operation
        previous?.cancel()
        publishActivity()
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: { operation.cancel() }
    }

    /// 收尾在被跟踪的任务内完成，确保运行时暂停返回时已清空活动记录。
    private func runRelocation(jobID: UUID, fileID: UUID, to url: URL, previous: Task<Void, Never>?) async throws {
        defer {
            relocations[jobID] = nil
            stopping.remove(jobID)
            publishActivity(); schedule()
        }
        await previous?.value
        try Task.checkCancellation()
        try await relocateStoppedSource(jobID: jobID, fileID: fileID, to: url)
    }

    /// 只在旧 worker 已退出且批次被 stopping 隔离后修改源定位；完整校验结束前持续持有用户授权。
    private func relocateStoppedSource(jobID: UUID, fileID: UUID, to url: URL) async throws {
        guard let job = jobs[jobID] else { throw UploadCoordinatorError.missingJob }
        var file = try await store.loadFile(id: fileID, in: job)
        guard !file.isDirectory, file.phase == .failed,
              let phase = file.failedPhase, [.preparing, .queued, .uploading].contains(phase),
              file.remoteReference == nil, !file.commits.contains(where: { $0.status == .pending }),
              let original = file.expectation, original.algorithm == .sha256, original.origin == .localOriginal else {
            throw UploadRecordError.invalid("只能重新定位已有原始 SHA-256 的待上传失败文件；目录或尚无原始基准的项目请重新添加，云端校验阶段可直接重试")
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let fingerprint = try await UploadSource.fingerprint(of: url,
            chunkSize: file.preparation?.partSize ?? file.sourceFingerprint?.chunkSize ?? 4 * 1024 * 1024)
        guard fingerprint.identity.size == file.source.size, fingerprint.identity.size == original.size,
              fingerprint.sha256 == original.digest,
              file.md5 == nil || file.md5 == fingerprint.md5,
              file.sha1 == nil || file.sha1 == fingerprint.sha1 else {
            throw UploadSourceError.contentMismatch(url.path)
        }
        let preparation = try file.preparation.map { try $0.bindingFingerprint(fingerprint) }
        let bookmark = try UploadSource.bookmark(for: url)
        guard try UploadSource.identity(of: url) == fingerprint.identity else { throw UploadSourceError.changed(url.path) }
        try Task.checkCancellation()
        guard !closed, !globallySuspended, !suspendedProviders.contains(job.account.provider),
              jobs[jobID]?.account == job.account, jobs[jobID]?.cancellationRequested == false else { throw CancellationError() }
        file.source = UploadLocalSource(url: url, bookmark: bookmark, size: file.source.size,
            modificationDate: Date(timeIntervalSince1970: Double(fingerprint.identity.modifiedNanoseconds) / 1_000_000_000),
            resourceIdentifier: try JSONEncoder().encode(fingerprint.identity))
        file.preparation = preparation
        file.sourceFingerprint = preparation == nil ? fingerprint : nil
        file.md5 = fingerprint.md5; file.sha1 = fingerprint.sha1
        file.phase = phase; file.failedPhase = nil; file.error = nil
        do {
            try await saveFile(file)
            jobs[jobID]!.error = nil
            try await rebuildAggregate(jobID)
            jobs[jobID]!.phase = .queued
            try await persistJob(jobID)
        } catch {
            // 新定位可能已经原子写入文件记录；聚合写入失败后停在失败态，由显式重试继续。
            jobs[jobID]!.phase = .failed; jobs[jobID]!.error = "重新定位检查点未保存完整：\(error.localizedDescription)"
            emit()
            throw error
        }
    }

    /// 取消不删除已成功内容；在途提交先收尾，未决结果保留且阻止移除记录。
    public func cancel(_ id: UUID) async throws {
        guard jobs[id] != nil else { throw UploadCoordinatorError.missingJob }
        guard !stopping.contains(id) else { throw UploadCoordinatorError.busy }
        stopping.insert(id)
        defer { stopping.remove(id) }
        jobs[id]!.cancellationRequested = true
        let task = workers[id]?.task; task?.cancel()
        var saveError: (any Error)?
        do { try await persistJob(id) } catch { saveError = error }
        await task?.value
        if let saveError { throw saveError }
        guard let job = jobs[id] else { throw UploadCoordinatorError.missingJob }
        for fileID in job.fileIDs {
            var file = try await store.loadFile(id: fileID, in: job)
            if file.replacement?.requiresCancellationRecovery == true {
                let env = try await environment(job.account)
                try await recoverReplacement(&file, environment: env, cancelling: true)
            }
            if file.commits.contains(where: { $0.status == .pending }) ||
                (file.sessionResultRecoveryRequired == true && file.remoteReference == nil) { throw UploadCoordinatorError.unconfirmedCommit }
            if ![.completed, .skipped].contains(file.phase) {
                file.phase = .cancelled; file.failedPhase = nil; file.error = nil; try await saveFile(file)
            }
        }
        jobs[id]!.phase = .cancelled; try await persistJob(id)
    }

    /// 只查询已记录的未决副作用，不创建目录或重新合并；取消后的任务也可以执行核对。
    public func reconcile(_ id: UUID) async throws {
        guard let job = jobs[id] else { throw UploadCoordinatorError.missingJob }
        guard workers[id] == nil, !stopping.contains(id) else { throw UploadCoordinatorError.busy }
        stopping.insert(id)
        defer { stopping.remove(id); schedule() }
        let env = try await environment(job.account)
        guard env.destination.account == job.account else { throw UploadDestinationError.otherAccount }
        var directories: [String: RemoteReference] = ["": job.destination]
        for fileID in job.fileIDs {
            var file = try await store.loadFile(id: fileID, in: job)
            if file.replacement?.requiresCancellationRecovery == true {
                try await recoverReplacement(&file, environment: env, cancelling: job.cancellationRequested)
            }
            if file.sessionResultRecoveryRequired == true {
                let parentPath = file.relativePath.split(separator: "/").dropLast().joined(separator: "/")
                guard let parent = directories[parentPath] else { throw UploadCoordinatorError.missingParent(parentPath) }
                try await recoverSessionResult(&file, parent: parent, environment: env)
            } else if file.commits.contains(where: { $0.status == .pending }) {
                let parentPath = file.relativePath.split(separator: "/").dropLast().joined(separator: "/")
                guard let parent = directories[parentPath] else { throw UploadCoordinatorError.missingParent(parentPath) }
                do { try await inspect(&file, parent: parent, environment: env) }
                catch UploadCoordinatorError.rejectedCommit { /* 明确拒绝已经核对，可继续收尾取消。 */ }
            }
            if file.isDirectory, let reference = file.remoteReference { directories[file.relativePath] = reference }
        }
        if job.cancellationRequested {
            for fileID in job.fileIDs {
                var file = try await store.loadFile(id: fileID, in: job)
                if ![.completed, .skipped].contains(file.phase) {
                    file.phase = .cancelled; file.failedPhase = nil; file.error = nil; try await saveFile(file)
                }
            }
            jobs[id]!.phase = .cancelled
        }
        try await rebuildAggregate(id)
    }

    /// 移除只把本地任务记录放入废纸篓；独立校验库和成功云端文件保留。
    public func remove(_ id: UUID) async throws {
        guard let job = jobs[id] else { throw UploadCoordinatorError.missingJob }
        guard workers[id] == nil, !stopping.contains(id), job.phase.isTerminal || job.isPaused else { throw UploadCoordinatorError.busy }
        stopping.insert(id)
        defer { stopping.remove(id) }
        for fileID in job.fileIDs {
            let file = try await store.loadFile(id: fileID, in: job)
            if file.commits.contains(where: { $0.status == .pending }) ||
                file.replacement?.requiresCancellationRecovery == true ||
                (file.sessionResultRecoveryRequired == true && file.remoteReference == nil) {
                throw UploadCoordinatorError.unconfirmedCommit
            }
        }
        for fileID in job.fileIDs {
            if let prepared = try await store.loadFile(id: fileID, in: job).preparation, let reference = prepared.secretReference {
                if let secrets { try await secrets.delete(reference: reference) }
                else {
                    let env = try await environment(job.account)
                    guard env.destination.account == job.account else { throw UploadDestinationError.otherAccount }
                    try await env.releasePreparation(prepared)
                }
            }
        }
        try await store.moveJobToTrash(id: id)
        jobs[id] = nil; emit()
    }

    /// 优先级只影响尚未执行批次，不打断正在确认的请求。
    public func prioritize(_ id: UUID) async throws {
        guard jobs[id] != nil else { throw UploadCoordinatorError.missingJob }
        jobs[id]!.priority = (jobs.values.map(\.priority).max() ?? 0) + 1
        try await persistJob(id); schedule()
    }

    /// 降低并发保留已有 worker，新批次按更新后的上限排队。
    public func updateMaximumConcurrentJobs(_ count: Int) throws {
        guard (1...4).contains(count) else { throw UploadRecordError.invalid("同时上传批次数必须为 1～4") }
        maximumConcurrentJobs = count; schedule()
    }

    /// 新值只影响下次创建的文件执行器，不中断当前文件已经在途的分片。
    public func updateMaximumConcurrentParts(_ count: Int) throws {
        guard (1...4).contains(count) else { throw UploadRecordError.invalid("单文件上传并发数必须为 1～4") }
        maximumConcurrentParts = count
    }

    /// 正常退出等待 worker 写完最后回执；不把运行任务改成手动暂停。
    public func shutdown() async {
        closed = true
        let tasks = workers.values.map(\.task)
        let relocating = Array(relocations.values)
        for task in tasks { task.cancel() }
        for task in relocating { task.cancel() }
        for task in tasks { await task.value }
        for task in relocating { _ = try? await task.value }
        for observer in observers.values { observer.finish() }
        observers.removeAll()
        publishActivity()
        for observer in activityObservers.values { observer.finish() }
        activityObservers.removeAll()
    }

    private func schedule() {
        guard !closed, !globallySuspended else { return }
        let pending = jobs.values.filter { !$0.isPaused && !$0.cancellationRequested && !$0.phase.isTerminal && workers[$0.id] == nil && !stopping.contains($0.id) && !suspendedProviders.contains($0.account.provider) }
            .sorted { $0.priority == $1.priority ? $0.createdAt < $1.createdAt : $0.priority > $1.priority }
        for job in pending.prefix(max(0, maximumConcurrentJobs - Set(workers.keys).union(relocations.keys).count)) {
            let token = UUID()
            let task = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.run(job.id, token: token)
            }
            workers[job.id] = Worker(token: token, task: task)
        }
        publishActivity()
    }

    private func run(_ id: UUID, token: UUID) async {
        var terminal: UploadJob?
        do {
            if jobs[id]?.scanCompletedAt == nil { try await scan(id) }
            try Task.checkCancellation()
            guard try await prepareContent(id) else { throw CancellationError() }
            try Task.checkCancellation()
            guard let job = jobs[id] else { throw UploadCoordinatorError.missingJob }
            let env = try await environment(job.account)
            guard env.destination.account == job.account else { throw UploadDestinationError.otherAccount }
            var directories: [String: RemoteReference] = ["": job.destination]
            var skippedDirectories: Set<String> = []
            for fileID in job.fileIDs {
                try Task.checkCancellation()
                var file = try await store.loadFile(id: fileID, in: job)
                if file.isDirectory, let ref = file.remoteReference { directories[file.relativePath] = ref }
                if file.isDirectory, file.phase == .skipped { skippedDirectories.insert(file.relativePath) }
                if ![.completed, .skipped, .cancelled].contains(file.phase) {
                    // 父先子后的扫描顺序保证祖先状态已知；按组件逐层查 Set，不扫描全部跳过目录。
                    var ancestor = (file.relativePath as NSString).deletingLastPathComponent
                    while !ancestor.isEmpty {
                        if skippedDirectories.contains(ancestor) {
                            file.phase = .skipped; file.failedPhase = nil; file.error = nil
                            try await saveFile(file)
                            break
                        }
                        ancestor = (ancestor as NSString).deletingLastPathComponent
                    }
                }
                if [.completed, .skipped, .cancelled, .failed].contains(file.phase) { continue }
                let parentPath = file.relativePath.split(separator: "/").dropLast().joined(separator: "/")
                do {
                    guard let parent = directories[parentPath] else { throw UploadCoordinatorError.missingParent(parentPath) }
                    try await process(&file, jobID: id, parent: parent, environment: env)
                    if file.isDirectory, file.phase == .skipped { skippedDirectories.insert(file.relativePath) }
                    if file.isDirectory, let ref = file.remoteReference { directories[file.relativePath] = ref }
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    if case UploadCoordinatorError.persistence = error { throw error }
                    file = try await store.loadFile(id: fileID, in: job)
                    let failedPhase = file.phase == .failed ? file.failedPhase : file.phase
                    file.failedPhase = failedPhase; file.phase = .failed; file.error = error.localizedDescription
                    try await saveFile(file)
                }
            }
            try await rebuildAggregate(id)
            if jobs[id]!.failedCount > 0 { jobs[id]!.phase = .failed }
            else if jobs[id]!.skippedCount == jobs[id]!.fileIDs.count { jobs[id]!.phase = .skipped }
            else { jobs[id]!.phase = .completed }
            try await persistJob(id)
            terminal = jobs[id]
        } catch {
            // 客户端自行撤销可抛 CancellationError，但当前任务并未被暂停；不能立即重排形成取消死循环。
            if !Task.isCancelled, let job = jobs[id],
               !(error is CancellationError) || (!globallySuspended && !suspendedProviders.contains(job.account.provider) && !job.isPaused && !job.cancellationRequested) {
                jobs[id]!.phase = .failed; jobs[id]!.error = error.localizedDescription
                do { try await persistJob(id); terminal = jobs[id] }
                catch { jobs[id]!.error = "\(jobs[id]!.error ?? "上传失败")；错误状态也未能保存：\(error.localizedDescription)" }
            }
        }
        if workers[id]?.token == token { workers[id] = nil }
        stageSamples[id] = nil
        emit(); schedule()
        publishActivity()
        // 先移除当前 worker，通知回调重入 pause/suspend/shutdown 才不会等待自身。
        if let terminal, !closed, !terminal.cancellationRequested { await onBatchFinished?(terminal) }
    }

    /// 未完成扫描没有任何远端副作用，恢复时可覆盖稳定 ID 对应的本地扫描检查点。
    private func scan(_ id: UUID) async throws {
        guard let job = jobs[id], let selections = job.selections, !selections.isEmpty else { throw UploadCoordinatorError.missingSelections }
        let roots = try selections.map { try UploadSource.resolve(bookmark: $0.bookmark) }
        let accessed = roots.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in accessed { url.stopAccessingSecurityScopedResource() } }
        jobs[id]!.fileIDs = []; jobs[id]!.totalBytes = 0; jobs[id]!.completedBytes = 0
        jobs[id]!.completedCount = 0; jobs[id]!.failedCount = 0; jobs[id]!.skippedCount = 0
        jobs[id]!.phase = .preparing
        try await persistJob(id)
        try await UploadSource.scan(selections: roots, onEvent: { [weak self] event in
            guard let self else { throw CancellationError() }
            try await self.stage(event, jobID: id)
        })
        try Task.checkCancellation()
        jobs[id]!.scanCompletedAt = .now; jobs[id]!.phase = .queued
        try await persistJob(id)
    }

    private func stage(_ event: UploadSourceScanEvent, jobID: UUID) async throws {
        try Task.checkCancellation()
        guard let job = jobs[jobID] else { throw UploadCoordinatorError.missingJob }
        switch event {
        case .issue(let issue): throw UploadCoordinatorError.scanIssue(issue.reason)
        case .entry(let entry):
            let id = stableID(jobID: jobID, relativePath: entry.relativePath)
            guard !job.fileIDs.contains(id) else { throw UploadCoordinatorError.scanIssue("所选根目录具有重复相对路径：\(entry.relativePath)") }
            let source = UploadLocalSource(url: entry.url, bookmark: try UploadSource.bookmark(for: entry.url),
                                           size: entry.kind == .directory ? 0 : entry.identity.size,
                                           resourceIdentifier: try JSONEncoder().encode(entry.identity))
            let file = UploadFile(id: id, jobID: jobID, relativePath: entry.relativePath, isDirectory: entry.kind == .directory, source: source, phase: .queued)
            do { try await store.stageFile(file, account: job.account) }
            catch { throw UploadCoordinatorError.persistence(error.localizedDescription) }
            jobs[jobID]!.fileIDs.append(id); jobs[jobID]!.totalBytes += source.size
            // 每文件已原子保存；完整 manifest 在扫描结束或暂停时发布，避免逐项重写增长清单。
            emit()
        }
    }

    private struct ContentEntry: Encodable {
        let path: String
        let directory: Bool
        let size: Int64
        let sha256: String?
    }

    /// 首次远端写入前完成全部源基准；只暂存指纹，发送时复用，不额外读取第二遍完整文件。
    /// 已确认远端对象只使用已有摘要，保留本地文件移走后的独立回读能力。
    private func prepareContent(_ id: UUID) async throws -> Bool {
        guard let job = jobs[id] else { throw UploadCoordinatorError.missingJob }
        if job.contentSignature != nil { return job.duplicateOfJobID == nil }
        var entries: [ContentEntry] = []
        var hasRemoteState = false
        var hasCompleteBaseline = true
        for fileID in job.fileIDs {
            try Task.checkCancellation()
            var file = try await store.loadFile(id: fileID, in: job)
            hasRemoteState = hasRemoteState || file.remoteReference != nil || file.preparation != nil || !file.commits.isEmpty
            if !file.isDirectory, file.remoteReference == nil, file.preparation == nil,
               ![.completed, .skipped, .cancelled].contains(file.phase) {
                do {
                    if file.sourceFingerprint == nil {
                        file.phase = .preparing; try await saveFile(file)
                        let fingerprint = try await fingerprint(file)
                        file.expectation = try IntegrityExpectation(algorithm: .sha256, digest: fingerprint.sha256,
                                                                   origin: .localOriginal, size: file.source.size)
                        file.sourceFingerprint = fingerprint
                        file.md5 = fingerprint.md5; file.sha1 = fingerprint.sha1
                        try await saveFile(file)
                    }
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    if case UploadCoordinatorError.persistence = error { throw error }
                    file = try await store.loadFile(id: fileID, in: job)
                    file.failedPhase = file.phase == .failed ? file.failedPhase : file.phase
                    file.phase = .failed; file.error = error.localizedDescription
                    try await saveFile(file)
                    hasCompleteBaseline = false
                }
            }
            let digest = file.expectation?.algorithm == .sha256 ? file.expectation?.digest : nil
            if !file.isDirectory && digest == nil { hasCompleteBaseline = false }
            entries.append(ContentEntry(path: file.relativePath, directory: file.isDirectory,
                                        size: file.source.size, sha256: digest))
        }
        // 旧记录缺少原始摘要时保持未知，不能靠名称和大小判相同或要求已完成项的本地源仍存在。
        guard hasCompleteBaseline else { return true }
        let signature = try contentSignature(entries)
        var knownSignatures: [UUID: String] = [:]
        // 旧版暂停批次可能尚无批次摘要，但已有完整文件摘要；只读检查点复用，不重读其本地源。
        let candidates = jobs.values.filter {
            $0.id != id && $0.account == job.account && $0.destination == job.destination &&
            $0.contentSignature == nil && $0.scanCompletedAt != nil && $0.fileIDs.count == job.fileIDs.count &&
            $0.totalBytes == job.totalBytes && isDuplicateCandidate($0, for: job)
        }
        for candidate in candidates {
            if let signature = try await knownContentSignature(candidate) { knownSignatures[candidate.id] = signature }
        }
        try Task.checkCancellation()
        // 判定与占位发布之间没有 await；并行准备的相同批次只能先到者继续。
        let existing = jobs.values.filter {
            $0.id != id && $0.account == job.account && $0.destination == job.destination &&
            ($0.contentSignature ?? knownSignatures[$0.id]) == signature &&
            isDuplicateCandidate($0, for: job)
        }.min { $0.createdAt < $1.createdAt }
        jobs[id]!.contentSignature = signature
        if !hasRemoteState, let existing {
            jobs[id]!.duplicateOfJobID = existing.id
            jobs[id]!.isPaused = true; jobs[id]!.phase = .queued
        }
        try await persistJob(id)
        return jobs[id]?.duplicateOfJobID == nil
    }

    /// 默认单上传队列可能在核对前已传完原批次，保留添加时活动且现已成功的候选。
    private func isDuplicateCandidate(_ candidate: UploadJob, for job: UploadJob) -> Bool {
        guard !candidate.cancellationRequested, candidate.failedCount == 0, candidate.duplicateOfJobID == nil else { return false }
        return !candidate.phase.isTerminal ||
            (candidate.phase == .completed && job.duplicateCandidateIDs?.contains(candidate.id) == true)
    }

    /// 旧活动批次只从完整原始 SHA-256 清单取得签名；有任一文件缺失基准就保持未知。
    private func knownContentSignature(_ job: UploadJob) async throws -> String? {
        var entries: [ContentEntry] = []
        for id in job.fileIDs {
            try Task.checkCancellation()
            let file = try await store.loadFile(id: id, in: job)
            guard file.phase != .failed else { return nil }
            let digest = file.expectation?.algorithm == .sha256 ? file.expectation?.digest : nil
            guard file.isDirectory || digest != nil else { return nil }
            entries.append(ContentEntry(path: file.relativePath, directory: file.isDirectory,
                                        size: file.source.size, sha256: digest))
        }
        return try contentSignature(entries)
    }

    /// 排序消除扫描顺序差异；路径和目录项本身参与摘要，改名或增删空目录不会误判重复。
    private func contentSignature(_ entries: [ContentEntry]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var hash = SHA256()
        hash.update(data: Data("FerryUploadContent/v1\n".utf8))
        hash.update(data: try encoder.encode(entries.sorted { $0.path < $1.path }))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 在原始文件身份不变时建立一次完整摘要，拒绝把扫描后被改写的内容替换为新基准。
    private func fingerprint(_ file: UploadFile) async throws -> UploadSourceFingerprint {
        let url = try file.source.bookmark.map { try UploadSource.resolve(bookmark: $0) } ?? file.source.url
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let result = try await UploadSource.fingerprint(of: url, chunkSize: 4 * 1024 * 1024)
        guard result.identity.size == file.source.size else { throw UploadSourceError.changed(url.path) }
        if let identity = file.source.resourceIdentifier,
           try JSONDecoder().decode(UploadSourceIdentity.self, from: identity) != result.identity {
            throw UploadSourceError.changed(url.path)
        }
        if let original = file.expectation, original.algorithm == .sha256, original.digest != result.sha256 {
            throw UploadSourceError.changed(url.path)
        }
        return result
    }

    /// 原会话不可用先查产物；只有精确结果进入完整回读，未知结果保留原会话而不重新准备。
    private func process(_ file: inout UploadFile, jobID: UUID, parent: RemoteReference, environment env: UploadEnvironment) async throws {
        do {
            try await processCurrent(&file, jobID: jobID, parent: parent, environment: env)
        } catch let error as QuarkStorageError where error.status == 404 && error.code == "NoSuchUpload" {
            guard env.destination.account.provider == .quark, !file.isDirectory,
                  let job = jobs[jobID] else { throw error }
            file = try await store.loadFile(id: file.id, in: job)
            guard file.preparation != nil, file.remoteReference == nil else { throw error }
            file.sessionResultRecoveryRequired = true
            file.error = "原上传会话不可用，云端产物仍待核对；未重新上传。"
            try await saveFile(file)
            try Task.checkCancellation()
            try await recoverSessionResult(&file, parent: parent, environment: env)
            try await verify(&file, environment: env)
        }
    }

    private func processCurrent(_ file: inout UploadFile, jobID: UUID, parent: RemoteReference, environment env: UploadEnvironment) async throws {
        if file.sessionResultRecoveryRequired == true {
            try await recoverSessionResult(&file, parent: parent, environment: env)
            try await verify(&file, environment: env)
            return
        }
        guard jobs[jobID]?.scanCompletedAt != nil else { throw UploadCoordinatorError.missingSelections }
        let hadPendingCommit = file.commits.contains(where: { $0.status == .pending })
        if hadPendingCommit {
            try await inspect(&file, parent: parent, environment: env)
        }
        if file.isDirectory, file.remoteReference != nil {
            if !hadPendingCommit { try await refreshRemoteName(&file, parent: parent, environment: env) }
            file.phase = .completed; try await saveFile(file); return
        }
        if !file.isDirectory, file.remoteReference != nil {
            if let replacement = file.replacement,
               ![.initial, .snapshotPending, .snapshotReady].contains(replacement.stage) {
                try await publishReplacement(&file, environment: env)
                return
            }
            if !hadPendingCommit { try await refreshRemoteName(&file, parent: parent, environment: env) }
            try await verify(&file, environment: env); return
        }
        let job = jobs[jobID]!
        if file.remoteName == nil {
            let entries = try await env.listDirectory(parent)
            let original = (file.relativePath as NSString).lastPathComponent
            let matches = entries.filter { LocalPath.key($0.name) == LocalPath.key(original) }
            if let existing = matches.first {
                if file.isDirectory && existing.isDirectory {
                    file.remoteName = existing.name; file.remoteReference = existing.reference; file.phase = .completed
                    try await saveFile(file); return
                }
                switch job.conflictPolicy {
                case .skip: file.phase = .skipped; try await saveFile(file); return
                case .replace:
                    guard env.replacement != nil, !file.isDirectory, !existing.isDirectory else {
                        throw UploadCoordinatorError.unsafeReplacement
                    }
                    let replacement = try UploadReplacementState(fileID: file.id, parent: parent, original: existing)
                    file.replacement = replacement
                    file.remoteName = replacement.stagingName
                case .keepBoth:
                    let used = Set(entries.map { LocalPath.key($0.name) })
                    var number = 1; var candidate = LocalPath.numbered(original, number)
                    while used.contains(LocalPath.key(candidate)) { number += 1; candidate = LocalPath.numbered(original, number) }
                    file.remoteName = candidate
                }
            } else { file.remoteName = original }
            try await saveFile(file)
        }
        if let replacement = file.replacement,
           [.initial, .snapshotPending].contains(replacement.stage) {
            guard let strategy = env.replacement else { throw UploadCoordinatorError.unsafeReplacement }
            let jobID = file.jobID, fileID = file.id
            _ = try await UploadReplacementPublisher(destination: strategy, integrity: integrity).prepare(replacement,
                checkpoint: { [weak self] state in
                    guard let self else { throw CancellationError() }
                    try await self.replacementCheckpoint(state, jobID: jobID, fileID: fileID, phase: .preparing)
                })
            file = try await store.loadFile(id: fileID, in: jobs[jobID]!)
        }
        try Task.checkCancellation()
        if file.isDirectory {
            try await validateUploadParent(parent, environment: env)
            let commit = UploadCommit(kind: .createDirectory)
            file.commits.append(commit); file.phase = .committing; try await saveFile(file)
            // 尚未调用目录策略时可准确拒绝本地意图；进入策略后的取消仍保留未知结果。
            if Task.isCancelled {
                file.commits[file.commits.count - 1].status = .rejected
                try await saveFile(file)
                throw CancellationError()
            }
            let fileID = file.id
            do {
                _ = try await env.makeDirectory(parent: parent, name: file.remoteName!, onCreated: { [weak self] reference in
                    guard let self else { throw CancellationError() }
                    try await self.directoryCreated(reference, fileID: fileID, jobID: jobID, commitID: commit.id, account: job.account, parent: parent)
                })
            } catch let error as UploadDirectoryNotSubmitted {
                if let index = file.commits.firstIndex(where: { $0.id == commit.id }) {
                    file.commits[index].status = .rejected
                }
                try await saveFile(file)
                throw error.underlying
            }
            file = try await store.loadFile(id: fileID, in: jobs[jobID]!)
            try await refreshRemoteName(&file, parent: parent, environment: env)
            file.phase = .completed; try await saveFile(file)
            return
        }
        // 只在仍需本地字节时恢复源授权；无缺片仍由引擎严格核对回执和原服务端会话。
        let needsLocalSource: Bool
        if let prepared = file.preparation, prepared.isReadyForTransfer, !prepared.requiresRechunking {
            needsLocalSource = !prepared.isInstant && !Set(file.parts.map(\.index)).isSuperset(of: prepared.pendingParts)
        } else { needsLocalSource = true }
        let localURL: URL
        if needsLocalSource, let bookmark = file.source.bookmark { localURL = try UploadSource.resolve(bookmark: bookmark) }
        else { localURL = file.source.url }
        let accessed = needsLocalSource && localURL.startAccessingSecurityScopedResource()
        defer { if accessed { localURL.stopAccessingSecurityScopedResource() } }
        if file.preparation == nil {
            file.phase = .preparing; try await saveFile(file)
            let fingerprint: UploadSourceFingerprint
            if let saved = file.sourceFingerprint { fingerprint = saved }
            else { fingerprint = try await self.fingerprint(file) }
            guard try UploadSource.identity(of: localURL) == fingerprint.identity else { throw UploadSourceError.changed(localURL.path) }
            file.expectation = try IntegrityExpectation(algorithm: .sha256, digest: fingerprint.sha256, origin: .localOriginal, size: file.source.size)
            file.sourceFingerprint = fingerprint
            file.md5 = fingerprint.md5; file.sha1 = fingerprint.sha1; try await saveFile(file)
            try Task.checkCancellation()
            guard try await prepare(&file, fingerprint: fingerprint, parent: parent, environment: env) else { return }
            file = try await store.loadFile(id: file.id, in: jobs[jobID]!)
        }
        guard var prepared = file.preparation else { throw UploadDestinationError.invalidPreparation }
        if prepared.requiresRechunking {
            let fingerprint = try await UploadSource.fingerprint(of: localURL, chunkSize: prepared.partSize)
            prepared = try prepared.bindingFingerprint(fingerprint)
            file.preparation = prepared; try await saveFile(file)
        }
        if !prepared.isReadyForTransfer {
            prepared = try await env.destination.finishPreparation(prepared, onPrepared: { [weak self] prepared in
                guard let self else { throw CancellationError() }
                try await self.prepared(prepared, jobID: jobID)
            })
            file = try await store.loadFile(id: file.id, in: jobs[jobID]!)
        }
        if !prepared.isInstant, needsLocalSource {
            prepared = try await rapidUpload(&file, localURL: localURL, parent: parent, environment: env)
        }
        try Task.checkCancellation()
        if prepared.isInstant, let reference = prepared.remoteReference {
            file.remoteReference = reference; file.phase = .verifying; try await saveFile(file)
        } else {
            file.phase = .uploading; try await saveFile(file)
            let fileID = file.id, relativePath = file.relativePath
            let receipts: [UploadPartReceipt]
            do {
                defer { stageSamples[jobID] = nil; emit() }
                receipts = try await UploadEngine(destination: env.destination, budget: budget,
                    maximumConcurrentParts: maximumConcurrentParts).upload(localURL: localURL, prepared: prepared, receipts: file.parts,
                    onReceipt: { [weak self] receipt in
                        guard let self else { throw CancellationError() }
                        try await self.received(receipt, fileID: fileID, jobID: jobID)
                    }, onProgress: { [weak self] progress in
                        guard let self else { throw CancellationError() }
                        try await self.updateStage(jobID: jobID, fileID: fileID, relativePath: relativePath,
                            phase: .uploading, bytes: progress.confirmedBytes, total: progress.totalBytes)
                    })
            }
            file = try await store.loadFile(id: file.id, in: jobs[jobID]!)
            try await validateUploadParent(parent, environment: env)
            let commit = UploadCommit(kind: .merge)
            file.commits.append(commit); file.phase = .committing; try await saveFile(file)
            // 尚未调用合并策略时可准确拒绝本地意图；进入策略后的取消仍保留未知结果。
            if Task.isCancelled {
                file.commits[file.commits.count - 1].status = .rejected
                try await saveFile(file)
                throw CancellationError()
            }
            let reference = try await env.destination.complete(prepared, receipts: receipts)
            file.remoteReference = reference; file.commits[file.commits.count - 1].status = .confirmed
            file.commits[file.commits.count - 1].finalObject = reference; file.phase = .verifying
            try await saveFile(file)
        }
        try await refreshRemoteName(&file, parent: parent, environment: env)
        try await verify(&file, environment: env)
    }

    /// 只在原会话未发片时尝试一次快速路径；明确未命中继续原会话，未知提交结果禁止重放。
    private func rapidUpload(_ file: inout UploadFile, localURL: URL, parent: RemoteReference, environment env: UploadEnvironment) async throws -> PreparedUpload {
        guard let original = file.preparation else { throw UploadDestinationError.invalidPreparation }
        guard jobs[file.jobID]?.conflictPolicy == .keepBoth,
              let proofLength = env.destination.rapidUploadProofLength, proofLength == 256 * 1024,
              original.source.identity.size > Int64(proofLength), file.parts.isEmpty,
              !file.commits.contains(where: { $0.kind == .rapidUpload && $0.status != .rejected }) else { return original }
        let jobID = file.jobID, fileID = file.id
        try await budget.consume(proofLength, direction: .upload)
        let result = try await budget.withPermit { [weak self] in
            guard let coordinator = self else { throw CancellationError() }
            try await coordinator.validateUploadParent(parent, environment: env)
            return try await env.destination.rapidUpload(original, onSubmitting: { bytes in
                try await coordinator.rapidSubmitting(fileID: fileID, jobID: jobID, requestBodyBytes: bytes)
            }, readProof: { range in
                try UploadSource.readProof(of: localURL, expected: original.source.identity, range: range)
            })
        }
        guard let job = jobs[jobID], job.account == original.account else { throw UploadDestinationError.otherAccount }
        file = try await store.loadFile(id: fileID, in: job)
        let pending = file.commits.lastIndex { $0.kind == .rapidUpload && $0.status == .pending }
        switch result {
        case .rejected(let error):
            if let pending { file.commits[pending].status = .rejected; try await saveFile(file) }
            throw error
        case .notMatched:
            guard let pending else { throw UploadDestinationError.invalidPreparation }
            file.commits[pending].status = .confirmed
            try await saveFile(file)
            return original
        case .created(let instant):
            try instant.validate()
            guard let pending, instant.isInstant, instant.fileID == fileID, instant.account == job.account,
                  instant.source == original.source, let reference = instant.remoteReference else {
                throw UploadDestinationError.invalidPreparation
            }
            file.preparation = instant; file.remoteReference = reference; file.phase = .verifying
            file.commits[pending].status = .confirmed; file.commits[pending].finalObject = reference
            try await saveFile(file)
            return instant
        }
    }

    /// Native 已构造证明与表单，但尚未提交；先持久化独立意图，取消或保存失败不得继续 POST。
    private func rapidSubmitting(fileID: UUID, jobID: UUID, requestBodyBytes: Int) async throws {
        try Task.checkCancellation()
        guard requestBodyBytes > 0, let job = jobs[jobID] else { throw UploadDestinationError.invalidPreparation }
        var file = try await store.loadFile(id: fileID, in: job)
        guard let prepared = file.preparation, prepared.account == job.account, !prepared.isInstant,
              !file.commits.contains(where: { $0.kind == .rapidUpload && $0.status != .rejected }) else {
            throw UploadDestinationError.invalidPreparation
        }
        file.commits.append(UploadCommit(kind: .rapidUpload, requestBodyBytes: requestBodyBytes))
        try await saveFile(file)
        if Task.isCancelled {
            file.commits[file.commits.count - 1].status = .rejected
            try await saveFile(file)
            throw CancellationError()
        }
    }

    /// 路径型百度目标在产生新写意图前重查身份；固定根目录及稳定 FID 网盘不增加逐片请求。
    private func validateUploadParent(_ parent: RemoteReference, environment env: UploadEnvironment) async throws {
        try Task.checkCancellation()
        guard env.destination.account.provider == .baidu else { return }
        if case .baidu(path: "/", fsID: 0) = parent { return }
        _ = try await env.listDirectory(parent)
        try Task.checkCancellation()
    }

    /// 预创建前先保存意图；无准确回执的失败保留 pending，明确拒绝才允许重新选择名称或显式重试。
    private func prepare(_ file: inout UploadFile, fingerprint: UploadSourceFingerprint, parent: RemoteReference,
                         environment env: UploadEnvironment) async throws -> Bool {
        let jobID = file.jobID
        var rejectedNames: Set<String> = []
        for attempt in 0...3 {
            try Task.checkCancellation()
            guard !file.commits.contains(where: { $0.kind == .prepare && $0.status == .pending }) else {
                throw UploadCoordinatorError.unconfirmedCommit
            }
            // 冲突重试已在上一轮重新列目录；首次准备仍须在哈希完成后重新核对父目录。
            if attempt == 0 { try await validateUploadParent(parent, environment: env) }
            let intent = UploadCommit(kind: .prepare)
            file.commits.append(intent)
            try await saveFile(file)
            // 策略尚未调用时的本地取消可确定无远端副作用，避免留下不必要的未决请求。
            if Task.isCancelled {
                file.commits[file.commits.count - 1].status = .rejected
                try await saveFile(file)
                throw CancellationError()
            }
            do {
                _ = try await env.destination.prepare(name: file.remoteName!, target: parent, source: fingerprint, fileID: file.id,
                    onPrepared: { [weak self] prepared in
                        guard let self else { throw CancellationError() }
                        try await self.prepared(prepared, jobID: jobID)
                    })
                guard let job = jobs[jobID] else { throw UploadCoordinatorError.missingJob }
                file = try await store.loadFile(id: file.id, in: job)
                guard file.preparation != nil else { throw UploadCoordinatorError.unconfirmedCommit }
                return true
            } catch {
                guard let job = jobs[jobID] else { throw UploadCoordinatorError.missingJob }
                file = try await store.loadFile(id: file.id, in: job)
                // 首次回调已经确认时，后续哈希协商或写入失败只能恢复原会话，不能拒绝后重新预创建。
                guard file.preparation == nil,
                      let index = file.commits.firstIndex(where: { $0.id == intent.id && $0.status == .pending }),
                      env.destination.preparationFailureIsDefinitive(error) || isNameConflict(error) else {
                    throw error
                }
                file.commits[index].status = .rejected
                try await saveFile(file)
                guard case UploadDestinationError.nameConflict = error else { throw error }
                switch job.conflictPolicy {
                case .skip:
                    file.phase = .skipped; try await saveFile(file); return false
                case .replace: throw UploadDestinationError.nameConflict
                case .keepBoth:
                    guard attempt < 3 else { throw UploadDestinationError.nameConflict }
                    let entries = try await env.listDirectory(parent)
                    if let current = file.remoteName { rejectedNames.insert(LocalPath.key(current)) }
                    let used = Set(entries.map { LocalPath.key($0.name) }).union(rejectedNames)
                    let original = (file.relativePath as NSString).lastPathComponent
                    var number = 1; var candidate = LocalPath.numbered(original, number)
                    while used.contains(LocalPath.key(candidate)) { number += 1; candidate = LocalPath.numbered(original, number) }
                    file.remoteName = candidate
                    try await saveFile(file)
                }
            }
        }
        throw UploadDestinationError.nameConflict
    }

    private func isNameConflict(_ error: any Error) -> Bool {
        if case UploadDestinationError.nameConflict = error { return true }
        return false
    }

    /// 独立发布检查点先保存，再归档快照实际回读时间；旧状态无时间时保留原摘要记录，不伪造本次校验。
    private func replacementCheckpoint(_ state: UploadReplacementState, jobID: UUID, fileID: UUID,
                                       phase: UploadPhase) async throws {
        guard let job = jobs[jobID], state.fileID == fileID else { throw UploadCoordinatorError.missingJob }
        var file = try await store.loadFile(id: fileID, in: job)
        file.replacement = state; file.phase = phase
        try await saveFile(file)
        try await archiveReplacementSnapshot(state, account: job.account)
    }

    /// 重用检查点中实际取得的旧内容证明；完成／恢复也补齐独立归档，不新增回读或校验时间。
    private func archiveReplacementSnapshot(_ state: UploadReplacementState, account: AccountKey) async throws {
        if let snapshot = state.snapshotObject, let digest = state.originalSHA256, let verifiedAt = state.snapshotVerifiedAt {
            let expectation = try IntegrityExpectation(algorithm: .sha256, digest: digest, origin: .remoteOriginal,
                size: state.original.size, reference: snapshot)
            let record = IntegrityRecord(id: state.fileID, account: account, reference: snapshot,
                expectation: expectation, actualDigest: digest, status: .verified, verifiedAt: verifiedAt, uploadFileID: state.fileID,
                originalFileName: state.original.name)
            do { try await integrityStore.saveIfChanged(record) }
            catch { throw UploadCoordinatorError.persistence(error.localizedDescription) }
        }
    }

    /// 核对入口只查询原意图；取消入口可以无覆盖恢复原名称，已经发布的内容继续保留并完整校验。
    private func recoverReplacement(_ file: inout UploadFile, environment env: UploadEnvironment,
                                    cancelling: Bool) async throws {
        guard let state = file.replacement, let strategy = env.replacement else {
            throw UploadCoordinatorError.unsafeReplacement
        }
        let jobID = file.jobID, fileID = file.id
        let checkpoint: @Sendable (UploadReplacementState) async throws -> Void = { [weak self] state in
            guard let self else { throw CancellationError() }
            try await self.replacementCheckpoint(state, jobID: jobID, fileID: fileID, phase: .publishing)
        }
        defer { verificationProgress[jobID] = nil; stageSamples[jobID] = nil; emit() }
        let progress: @Sendable (Int64, Int64) async throws -> Void = { [weak self] bytes, total in
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            try await self.replacementVerificationProgress(jobID: jobID, fileID: fileID, bytes: bytes, total: total)
        }
        let publisher = UploadReplacementPublisher(destination: strategy, integrity: integrity)
        let result = if cancelling {
            try await publisher.cancel(state, remoteVersion: file.expectation?.remoteVersion,
                onProgress: progress, checkpoint: checkpoint)
        } else {
            try await publisher.inspect(state, remoteVersion: file.expectation?.remoteVersion,
                onProgress: progress, checkpoint: checkpoint)
        }
        file = try await store.loadFile(id: fileID, in: jobs[jobID]!)
        if result.state.stage == .published, let final = result.state.finalObject {
            file.remoteReference = final; file.remoteName = result.state.original.name
            try await saveFile(file)
            if let record = result.finalIntegrityRecord {
                try await completeVerification(&file, record: record, environment: env)
            } else {
                try await verify(&file, environment: env)
            }
        }
    }

    /// 发布器完整校验暂存与最终对象；只消费本次真实记录，不再重复回读同一阶段。
    private func publishReplacement(_ file: inout UploadFile, environment env: UploadEnvironment) async throws {
        guard let state = file.replacement, let strategy = env.replacement,
              let staged = state.stagedObject ?? file.remoteReference,
              let expectation = file.expectation else { throw UploadDestinationError.invalidPreparation }
        let jobID = file.jobID, fileID = file.id
        defer { verificationProgress[jobID] = nil; stageSamples[jobID] = nil; emit() }
        let result = try await UploadReplacementPublisher(destination: strategy, integrity: integrity).publish(state,
            staged: staged, expectedSHA256: expectation.digest, size: file.source.size, remoteVersion: expectation.remoteVersion,
            onStagedVerification: { [weak self] record in
                guard let self else { throw CancellationError() }
                try await self.recordStagedVerification(record, jobID: jobID, fileID: fileID, environment: env)
            }, onProgress: { [weak self] bytes, total in
                try Task.checkCancellation()
                guard let self else { throw CancellationError() }
                try await self.replacementVerificationProgress(jobID: jobID, fileID: fileID, bytes: bytes, total: total)
            }, checkpoint: { [weak self] state in
                guard let self else { throw CancellationError() }
                try await self.replacementCheckpoint(state, jobID: jobID, fileID: fileID, phase: .publishing)
            })
        guard result.state.stage == .published, let final = result.state.finalObject,
              let record = result.finalIntegrityRecord else { throw UploadReplacementError.unconfirmed }
        file = try await store.loadFile(id: fileID, in: jobs[jobID]!)
        file.remoteReference = final; file.remoteName = result.state.original.name
        try await saveFile(file)
        try await completeVerification(&file, record: record, environment: env)
    }

    /// 与未决合并共用准确对象回执合同；查询失败/未确认时保持恢复标记，显式重试仍可再次查询。
    private func recoverSessionResult(_ file: inout UploadFile, parent: RemoteReference, environment env: UploadEnvironment) async throws {
        guard file.sessionResultRecoveryRequired == true, let prepared = file.preparation,
              prepared.account == env.destination.account, !file.isDirectory else {
            throw UploadDestinationError.invalidPreparation
        }
        if file.remoteReference != nil {
            file.phase = .verifying; file.failedPhase = nil; file.error = nil
            try await saveFile(file)
            return
        }
        switch try await env.inspectPreparedResult(prepared, parent) {
        case .unconfirmed:
            throw UploadCoordinatorError.unconfirmedCommit
        case .rejected(let reason):
            throw UploadCoordinatorError.rejectedCommit(reason)
        case .confirmed(let reference):
            let native = try JSONDecoder().decode(QuarkUploadSession.self, from: prepared.nativeSession)
            guard reference == .quark(fid: native.fileID) else { throw UploadDestinationError.remoteResultUnconfirmed }
            file.remoteReference = reference; file.phase = .verifying; file.failedPhase = nil; file.error = nil
            for index in file.commits.indices where file.commits[index].status == .pending && file.commits[index].kind == .merge {
                file.commits[index].status = .confirmed; file.commits[index].finalObject = reference
            }
            try await saveFile(file)
        }
    }

    private func inspect(_ file: inout UploadFile, parent: RemoteReference, environment env: UploadEnvironment) async throws {
        for index in file.commits.indices where file.commits[index].status == .pending {
            // 预创建／快速上传未知结果缺少准确产物回执，现有合并查询合同不能认领同名对象或解除意图。
            guard ![.prepare, .rapidUpload].contains(file.commits[index].kind) else { throw UploadCoordinatorError.unconfirmedCommit }
            switch try await env.inspectCommit(file.commits[index], file, parent) {
            case .unconfirmed: throw UploadCoordinatorError.unconfirmedCommit
            case .rejected(let reason):
                file.commits[index].status = .rejected; try await saveFile(file)
                throw UploadCoordinatorError.rejectedCommit(reason)
            case .confirmed(let reference):
                guard reference.provider == env.destination.account.provider, !reference.identifier.isEmpty else { throw UploadDestinationError.otherAccount }
                file.commits[index].status = .confirmed; file.commits[index].finalObject = reference
                file.remoteReference = reference; file.phase = file.isDirectory ? .committing : .verifying
                try await saveFile(file)
                try await refreshRemoteName(&file, parent: parent, environment: env)
                if file.isDirectory { file.phase = .completed; try await saveFile(file) }
            }
        }
    }

    /// 已接收的准确目录回执属于发起时账号，即使此时取消或换号也须先保存，之后才停止后续操作。
    private func directoryCreated(_ reference: RemoteReference, fileID: UUID, jobID: UUID,
                                  commitID: UUID, account: AccountKey, parent: RemoteReference) async throws {
        guard let job = jobs[jobID], job.account == account, reference.provider == account.provider,
              !reference.identifier.isEmpty else { throw UploadDestinationError.otherAccount }
        var file = try await store.loadFile(id: fileID, in: job)
        guard file.isDirectory, let index = file.commits.firstIndex(where: { $0.id == commitID && $0.kind == .createDirectory }),
              file.commits[index].status == .pending else { throw UploadDestinationError.invalidPreparation }
        switch reference {
        case .baidu(let path, let fsID):
            guard fsID > 0, case .baidu(let parentPath, _) = parent,
                  let relative = RemotePath.relativePath(of: path, in: parentPath),
                  RemotePath.components(of: relative, omittingEmpty: false).count == 1,
                  let name = file.remoteName, RemotePath.isSameComponent(relative, name) else {
                throw UploadDestinationError.invalidPreparation
            }
        case .quark(let fid):
            guard fid != "0", fid != parent.identifier else { throw UploadDestinationError.invalidPreparation }
        }
        file.remoteReference = reference
        file.commits[index].status = .confirmed; file.commits[index].finalObject = reference
        file.phase = .committing
        try await saveFile(file)
    }

    /// 服务端可能自动另存为其他名称；以已确认对象身份查询实际名称，绝不按请求名称认领对象。
    /// 调用前成功回执必须已经保存，目录查询失败只影响后续阶段，不会丢失合并结果。
    private func refreshRemoteName(_ file: inout UploadFile, parent: RemoteReference, environment env: UploadEnvironment) async throws {
        guard let reference = file.remoteReference else { throw UploadDestinationError.invalidPreparation }
        for attempt in 0..<6 {
            try Task.checkCancellation()
            let entries = try await env.listDirectory(parent)
            let exact = entries.filter { $0.reference == reference }
            if !exact.isEmpty {
                guard exact.count == 1, let entry = exact.first, entry.isDirectory == file.isDirectory,
                      file.isDirectory || entry.size == file.source.size else {
                    throw UploadDestinationError.remoteResultUnconfirmed
                }
                if file.remoteName != entry.name {
                    file.remoteName = entry.name
                    try await saveFile(file)
                }
                return
            }
            // 建目录和合并均可能先返回成功回执、后更新目录索引。仅查询准确对象，不重提副作用。
            if attempt < 5 { try await Task.sleep(for: .milliseconds(200 * (1 << attempt))) }
        }
        // 文件已由准确 fid 确认后可能被移动；名称刷新不应阻断随后按 fid 的完整内容回读。
        // 仅在所有原目录查询成功但准确对象缺失时继续；网络、账号、类型与大小错误仍原样失败。
        if !file.isDirectory, case .quark(let fid) = reference, !fid.isEmpty { return }
        throw UploadDestinationError.remoteResultUnconfirmed
    }

    private func verify(_ file: inout UploadFile, environment env: UploadEnvironment) async throws {
        guard let reference = file.remoteReference, let expectation = file.expectation, expectation.algorithm == .sha256 else {
            throw UploadDestinationError.invalidPreparation
        }
        if let replacement = file.replacement, replacement.stage != .published {
            try await publishReplacement(&file, environment: env)
            return
        }
        file.phase = .verifying; file.failedPhase = nil; file.error = nil; try await saveFile(file)
        let size = file.source.size
        let jobID = file.jobID, fileID = file.id
        verificationProgress[jobID] = .init(fileID: fileID, relativePath: file.relativePath, verifiedBytes: 0, totalBytes: size)
        stageSamples[jobID] = .init(fileID: fileID, relativePath: file.relativePath, phase: .verifying,
            startedAt: .now, initialBytes: 0, currentBytes: 0, totalBytes: size)
        emit()
        defer { verificationProgress[jobID] = nil; stageSamples[jobID] = nil; emit() }
        let record = try await integrity.verify(account: env.destination.account, reference: reference,
            expectedSHA256: expectation.digest, size: size, remoteVersion: expectation.remoteVersion, uploadFileID: file.id,
            resolve: { try await env.resolve(reference, size) },
            onProgress: { [weak self] bytes, total in
                try Task.checkCancellation()
                guard let self else { throw CancellationError() }
                try await self.updateVerification(jobID: jobID, fileID: fileID, bytes: bytes, total: total)
            })
        try await completeVerification(&file, record: record, environment: env)
    }

    /// 核对记录归属后先保存实际摘要；暂存不完成任务，错摘要仍保留证据并失败。
    private func saveVerification(_ record: IntegrityRecord, file: inout UploadFile,
                                  environment env: UploadEnvironment) async throws {
        try record.validate()
        guard let expectation = file.expectation, record.account == env.destination.account,
              record.account == jobs[file.jobID]?.account, record.reference == file.remoteReference,
              record.uploadFileID == file.id, record.expectation?.algorithm == .sha256,
              record.expectation?.digest == expectation.digest, record.expectation?.size == file.source.size,
              record.remoteVersion == expectation.remoteVersion, record.expectation?.origin == .localOriginal,
              record.status == .verified || record.status == .mismatch else {
            throw UploadRecordError.invalid("上传校验结果与当前文件或账号不一致")
        }
        do { try await integrityStore.save(record) }
        catch { throw UploadCoordinatorError.persistence(error.localizedDescription) }
        file.integrityRecordID = record.id
        guard record.status == .verified else { try await saveFile(file); throw UploadCoordinatorError.mismatch }
    }

    /// 暂存的完整校验结果先持久化，之后发布器才可继续 claim 与发布。
    private func recordStagedVerification(_ record: IntegrityRecord, jobID: UUID, fileID: UUID,
                                          environment env: UploadEnvironment) async throws {
        guard let job = jobs[jobID] else { throw UploadCoordinatorError.missingJob }
        var file = try await store.loadFile(id: fileID, in: job)
        try await saveVerification(record, file: &file, environment: env)
        try await saveFile(file)
    }

    /// 每次暂存／最终对象的真实回读从零开始，进度不充当可恢复的摘要依据。
    private func replacementVerificationProgress(jobID: UUID, fileID: UUID, bytes: Int64, total: Int64) async throws {
        if bytes == 0 {
            guard let job = jobs[jobID] else { throw UploadCoordinatorError.missingJob }
            var file = try await store.loadFile(id: fileID, in: job)
            guard total == file.source.size else { throw UploadRecordError.invalid("上传校验长度与源文件不一致") }
            file.phase = .verifying; file.failedPhase = nil; file.error = nil; try await saveFile(file)
            verificationProgress[jobID] = .init(fileID: fileID, relativePath: file.relativePath, verifiedBytes: 0, totalBytes: total)
            stageSamples[jobID] = .init(fileID: fileID, relativePath: file.relativePath, phase: .verifying,
                startedAt: .now, initialBytes: 0, currentBytes: 0, totalBytes: total)
            emit()
        } else {
            try updateVerification(jobID: jobID, fileID: fileID, bytes: bytes, total: total)
        }
    }

    /// 实际校验记录先落盘、完成检查点随后落盘，最后释放准备授权；各上传入口共用收尾。
    private func completeVerification(_ file: inout UploadFile, record: IntegrityRecord,
                                      environment env: UploadEnvironment) async throws {
        try await saveVerification(record, file: &file, environment: env)
        guard file.replacement == nil || file.replacement?.stage == .published else {
            throw UploadReplacementError.unconfirmed
        }
        if let replacement = file.replacement {
            try await archiveReplacementSnapshot(replacement, account: record.account)
        }
        file.phase = .completed; file.sessionResultRecoveryRequired = nil; try await saveFile(file)
        if let prepared = file.preparation {
            do {
                if let reference = prepared.secretReference, let secrets { try await secrets.delete(reference: reference) }
                else { try await env.releasePreparation(prepared) }
            }
            catch {
                jobs[file.jobID]!.error = "内容已校验完成，上传授权清理待重试：\(error.localizedDescription)"
                try await persistJob(file.jobID)
            }
        }
    }

    /// 会话与首次预创建确认原子保存；重复协商回调只更新同一会话，旧版无意图记录继续兼容。
    private func prepared(_ prepared: PreparedUpload, jobID: UUID) async throws {
        guard let job = jobs[jobID], prepared.account == job.account else { throw UploadDestinationError.otherAccount }
        var file = try await store.loadFile(id: prepared.fileID, in: job)
        file.preparation = prepared
        file.sourceFingerprint = nil
        // Quark 会先保存会话、再保存哈希协商结果；只确认首次意图，旧记录没有该意图也可继续。
        for index in file.commits.indices where file.commits[index].kind == .prepare && file.commits[index].status == .pending {
            file.commits[index].status = .confirmed
            file.commits[index].finalObject = prepared.remoteReference
        }
        try await saveFile(file)
    }

    /// 回执由引擎父任务串行交付；同步修改前保留旧聚合摘要，每片仍立即落盘。
    private func received(_ receipt: UploadPartReceipt, fileID: UUID, jobID: UUID) async throws {
        guard let job = jobs[jobID] else { throw UploadCoordinatorError.missingJob }
        var file = try await store.loadFile(id: fileID, in: job)
        guard !file.parts.contains(where: { $0.index == receipt.index }) else { throw UploadDestinationError.invalidReceipt }
        let previous = FileCheckpointSummary(confirmedBytes: Self.confirmedBytes(file), phase: file.phase)
        file.parts.append(receipt); try await saveFile(file, previous: previous)
    }

    private struct FileCheckpointSummary {
        let confirmedBytes: Int64
        let phase: UploadPhase
    }

    /// 文件状态先落盘，聚合随后保存；恢复时可从每文件检查点重建聚合。
    /// 只有实际 worker 驱动批次阶段；停止后的核对仅保存检查点，继续由显式重试或恢复决定。
    /// 仅串行回执入口传入刚读取的旧摘要；其余调用仍从存储读取原状态。
    private func saveFile(_ file: UploadFile, previous: FileCheckpointSummary? = nil) async throws {
        guard let job = jobs[file.jobID] else { throw UploadCoordinatorError.missingJob }
        do {
            let baseline: FileCheckpointSummary
            if let previous { baseline = previous }
            else {
                let stored = try await store.loadFile(id: file.id, in: job)
                baseline = .init(confirmedBytes: Self.confirmedBytes(stored), phase: stored.phase)
            }
            try await store.saveFile(file, in: job)
            let delta = Self.confirmedBytes(file) - baseline.confirmedBytes
            jobs[file.jobID]!.completedBytes = min(jobs[file.jobID]!.totalBytes, max(0, jobs[file.jobID]!.completedBytes + delta))
            jobs[file.jobID]!.completedCount += (file.phase == .completed ? 1 : 0) - (baseline.phase == .completed ? 1 : 0)
            jobs[file.jobID]!.failedCount += (file.phase == .failed ? 1 : 0) - (baseline.phase == .failed ? 1 : 0)
            jobs[file.jobID]!.skippedCount += (file.phase == .skipped ? 1 : 0) - (baseline.phase == .skipped ? 1 : 0)
            if workers[file.jobID] != nil, !jobs[file.jobID]!.isPaused && !jobs[file.jobID]!.cancellationRequested {
                jobs[file.jobID]!.phase = file.phase.isTerminal ? .queued : file.phase
            }
            try await persistJob(file.jobID)
        } catch let error as UploadCoordinatorError { throw error }
        catch { throw UploadCoordinatorError.persistence(error.localizedDescription) }
    }

    private static func confirmedBytes(_ file: UploadFile) -> Int64 {
        if file.isDirectory || file.phase == .skipped { return 0 }
        if file.phase == .completed || file.remoteReference != nil { return file.source.size }
        guard let prepared = file.preparation else { return 0 }
        let pending = prepared.pendingParts.reduce(Int64(0)) { $0 + min(prepared.partSize, prepared.source.identity.size - Int64($1) * prepared.partSize) }
        return prepared.source.identity.size - pending + file.parts.reduce(0) { $0 + $1.length }
    }

    private func rebuildAggregate(_ id: UUID) async throws {
        guard let job = jobs[id] else { throw UploadCoordinatorError.missingJob }
        let rebuilt = try await aggregate(job)
        // 读取期间可能收到暂停／取消；只合入聚合，不用旧快照覆盖当前执行意图。
        jobs[id]!.completedBytes = rebuilt.completedBytes; jobs[id]!.completedCount = rebuilt.completedCount
        jobs[id]!.failedCount = rebuilt.failedCount; jobs[id]!.skippedCount = rebuilt.skippedCount
        if rebuilt.failedCount > 0 { jobs[id]!.error = rebuilt.error }
        try await persistJob(id)
    }

    private struct Aggregate: Sendable {
        var completed = 0, failed = 0, skipped = 0
        var bytes: Int64 = 0
        var firstFailure: String?
    }

    /// 只累加已验证文件检查点的业务计数，不读取 actor 状态或推断批次执行阶段。
    private static func accumulating(_ previous: Aggregate, _ file: UploadFile) -> Aggregate {
        var result = previous
        result.bytes += confirmedBytes(file)
        if file.phase == .completed { result.completed += 1 }
        if file.phase == .failed {
            result.failed += 1
            if result.firstFailure == nil {
                result.firstFailure = "\(file.relativePath)：\(file.error ?? "上传失败，未记录具体原因")"
            }
        }
        if file.phase == .skipped { result.skipped += 1 }
        return result
    }

    /// 权威成员清单仅读取一次；文件逐项归并，不推断批次阶段或用户执行意图。
    private func aggregate(_ job: UploadJob) async throws -> UploadJob {
        let result = try await store.reduceFiles(in: job, initial: Aggregate(), Self.accumulating)
        var rebuilt = job
        rebuilt.completedBytes = result.bytes; rebuilt.completedCount = result.completed
        rebuilt.failedCount = result.failed; rebuilt.skippedCount = result.skipped
        if let firstFailure = result.firstFailure { rebuilt.error = "\(result.failed) 项失败：\(firstFailure)" }
        return rebuilt
    }

    /// 服务每读完一个有界范围后回调；只发布本轮单调进度，不触发任务落盘。
    private func updateVerification(jobID: UUID, fileID: UUID, bytes: Int64, total: Int64) throws {
        guard let current = verificationProgress[jobID], current.fileID == fileID else { throw CancellationError() }
        guard total == current.totalBytes, bytes >= current.verifiedBytes, bytes <= total else {
            throw UploadRecordError.invalid("云端回读校验进度无效")
        }
        verificationProgress[jobID] = .init(fileID: fileID, relativePath: current.relativePath,
                                           verifiedBytes: bytes, totalBytes: total)
        try updateStage(jobID: jobID, fileID: fileID, relativePath: current.relativePath,
                        phase: .verifying, bytes: bytes, total: total)
    }

    /// 入口进度只允许本轮单调推进；首帧保存恢复基线，之后只更新运行时样本并发布快照。
    private func updateStage(jobID: UUID, fileID: UUID, relativePath: String, phase: UploadPhase,
                             bytes: Int64, total: Int64) throws {
        guard bytes >= 0, bytes <= total else { throw UploadRecordError.invalid("传输阶段进度无效") }
        if var sample = stageSamples[jobID] {
            guard sample.fileID == fileID, sample.phase == phase, sample.totalBytes == total,
                  bytes >= sample.currentBytes else { throw UploadRecordError.invalid("传输阶段进度发生倒退") }
            sample.currentBytes = bytes; stageSamples[jobID] = sample
        } else {
            stageSamples[jobID] = .init(fileID: fileID, relativePath: relativePath, phase: phase,
                startedAt: .now, initialBytes: bytes, currentBytes: bytes, totalBytes: total)
        }
        emit()
    }

    /// 均速按当前文件本轮已确认的新增逻辑字节／真实经过时间计算，无轮询、无网络瞬时速度冒充。
    private func stageMetrics(for job: UploadJob) -> UploadStageMetrics? {
        guard !job.isPaused, !job.cancellationRequested, !job.phase.isTerminal,
              let sample = stageSamples[job.id], sample.phase == job.phase,
              sample.currentBytes > sample.initialBytes, sample.currentBytes < sample.totalBytes else { return nil }
        let duration = sample.startedAt.duration(to: .now).components
        let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        guard elapsed >= 0.1 else { return nil }
        let speed = Double(sample.currentBytes - sample.initialBytes) / elapsed
        return .init(fileID: sample.fileID, relativePath: sample.relativePath, phase: sample.phase,
                     averageBytesPerSecond: speed,
                     estimatedRemainingSeconds: Double(sample.totalBytes - sample.currentBytes) / speed)
    }

    private func persistJob(_ id: UUID) async throws {
        guard let job = jobs[id] else { throw UploadCoordinatorError.missingJob }
        do { try await store.saveJob(job) }
        catch { throw UploadCoordinatorError.persistence(error.localizedDescription) }
        emit()
    }

    private func stableID(jobID: UUID, relativePath: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data((jobID.uuidString + "/" + relativePath).utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    private func emit() { let value = snapshots(); for observer in observers.values { observer.yield(value) } }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func removeActivityObserver(_ id: UUID) { activityObservers[id] = nil }
    private func publishActivity() {
        let active = !workers.isEmpty || !relocations.isEmpty
        guard active != lastActivity else { return }
        lastActivity = active
        for observer in activityObservers.values { observer.yield(active) }
    }
}
