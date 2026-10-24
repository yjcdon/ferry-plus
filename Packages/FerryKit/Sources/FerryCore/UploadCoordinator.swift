import Foundation
import CryptoKit
import DownloadKit

public enum UploadCoordinatorError: Error, LocalizedError, Sendable {
    case missingJob, missingSelections, scanIssue(String), missingParent(String), unsafeReplacement
    case unconfirmedCommit, rejectedCommit(String), persistence(String), mismatch, busy
    public var errorDescription: String? {
        switch self {
        case .missingJob: "上传任务不存在"
        case .missingSelections: "上传检查点缺少完整源选择，请重新添加任务"
        case .scanIssue(let message): "上传源扫描未完成：\(message)"
        case .missingParent(let path): "上传父目录尚未成功创建：\(path)"
        case .unsafeReplacement: "网盘安全覆盖能力尚未验证，当前任务不能覆盖已有文件"
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
    private let environment: @Sendable (AccountKey) async throws -> UploadEnvironment
    private let onBatchFinished: (@Sendable (UploadJob) async -> Void)?
    private var jobs: [UUID: UploadJob] = [:]
    private var workers: [UUID: Worker] = [:]
    private var observers: [UUID: AsyncStream<[UploadJob]>.Continuation] = [:]
    private var activityObservers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var lastActivity = false
    private var globallySuspended = false
    private var suspendedProviders: Set<Provider> = []
    private var stopping: Set<UUID> = []
    private var closed = false

    public init(store: UploadStore, integrityStore: IntegrityStore, budget: TransferBudget,
                integrity: IntegrityService, secrets: (any UploadSecretStorage)? = nil, maximumConcurrentJobs: Int = 1,
                onBatchFinished: (@Sendable (UploadJob) async -> Void)? = nil,
                environment: @escaping @Sendable (AccountKey) async throws -> UploadEnvironment) throws {
        guard (1...4).contains(maximumConcurrentJobs) else { throw UploadRecordError.invalid("同时上传批次数必须为 1～4") }
        self.store = store; self.integrityStore = integrityStore; self.budget = budget; self.integrity = integrity
        self.secrets = secrets
        self.maximumConcurrentJobs = maximumConcurrentJobs; self.environment = environment
        self.onBatchFinished = onBatchFinished
    }

    deinit {
        for worker in workers.values { worker.task.cancel() }
        for observer in observers.values { observer.finish() }
        for observer in activityObservers.values { observer.finish() }
    }

    /// 恢复暂停意图和阶段；完成／失败项保留结果，不自动重复远端提交。
    public func restore() async throws {
        guard workers.isEmpty, jobs.isEmpty else { throw UploadCoordinatorError.busy }
        let restored = try await store.loadJobs()
        jobs = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })
        emit(); schedule()
    }

    /// 在扫描前保存所有选择及账号，整批清单完成后才能产生远端副作用。
    @discardableResult
    public func add(account: AccountKey, accountName: String, destination: RemoteReference,
                    selections: [UploadSelection], conflictPolicy: UploadConflictPolicy = .keepBoth) async throws -> UUID {
        guard !closed, !selections.isEmpty else { throw UploadCoordinatorError.missingSelections }
        let names = selections.map { $0.url.lastPathComponent }
        var job = UploadJob(account: account, accountName: accountName, title: names.count == 1 ? names[0] : "\(names[0]) 等 \(names.count) 项",
                            destination: destination, conflictPolicy: conflictPolicy)
        job.selections = selections
        try await store.saveJob(job)
        jobs[job.id] = job; emit(); schedule()
        return job.id
    }

    /// 摘要来自同一批次状态，不复制一份 UI 执行模型。
    public func snapshots() -> [UploadJob] { jobs.values.sorted { $0.createdAt < $1.createdAt } }

    /// 明细分页读取，避免展示列表时把整棵目录及所有分片常驻内存。
    public func files(jobID: UUID, offset: Int = 0, limit: Int = 100) async throws -> [UploadFile] {
        guard let job = jobs[jobID] else { throw UploadCoordinatorError.missingJob }
        guard offset >= 0, (1...500).contains(limit) else { throw UploadRecordError.invalid("上传明细分页无效") }
        var result: [UploadFile] = []
        for id in job.fileIDs.dropFirst(offset).prefix(limit) { result.append(try await store.loadFile(id: id, in: job)) }
        return result
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
    public func isExecuting() -> Bool { !workers.isEmpty }

    /// 仅 worker 活动变化时发布，供应用合并下载活动管理防休眠，无常驻轮询。
    public func activityUpdates() -> AsyncStream<Bool> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            activityObservers[id] = continuation; continuation.yield(!workers.isEmpty)
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
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
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
        guard !closed, globallySuspended, workers.isEmpty else { throw UploadCoordinatorError.busy }
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

    /// 继续只启动一个新 worker，旧 worker 未结束时不允许两代并写。
    public func resume(_ id: UUID) async throws {
        guard let job = jobs[id] else { throw UploadCoordinatorError.missingJob }
        guard workers[id] == nil, !stopping.contains(id), !job.cancellationRequested else { throw UploadCoordinatorError.busy }
        jobs[id]!.isPaused = false
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
            if file.commits.contains(where: { $0.status == .pending }) { throw UploadCoordinatorError.unconfirmedCommit }
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
        defer { stopping.remove(id) }
        let env = try await environment(job.account)
        guard env.destination.account == job.account else { throw UploadDestinationError.otherAccount }
        var directories: [String: RemoteReference] = ["": job.destination]
        for fileID in job.fileIDs {
            var file = try await store.loadFile(id: fileID, in: job)
            if file.commits.contains(where: { $0.status == .pending }) {
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
            if try await store.loadFile(id: fileID, in: job).commits.contains(where: { $0.status == .pending }) {
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

    /// 正常退出等待 worker 写完最后回执；不把运行任务改成手动暂停。
    public func shutdown() async {
        closed = true
        let tasks = workers.values.map(\.task)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
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
        for job in pending.prefix(max(0, maximumConcurrentJobs - workers.count)) {
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
            guard let job = jobs[id] else { throw UploadCoordinatorError.missingJob }
            let env = try await environment(job.account)
            guard env.destination.account == job.account else { throw UploadDestinationError.otherAccount }
            var directories: [String: RemoteReference] = ["": job.destination]
            for fileID in job.fileIDs {
                try Task.checkCancellation()
                var file = try await store.loadFile(id: fileID, in: job)
                if file.isDirectory, let ref = file.remoteReference { directories[file.relativePath] = ref }
                if [.completed, .skipped, .cancelled, .failed].contains(file.phase) { continue }
                let parentPath = file.relativePath.split(separator: "/").dropLast().joined(separator: "/")
                do {
                    guard let parent = directories[parentPath] else { throw UploadCoordinatorError.missingParent(parentPath) }
                    try await process(&file, jobID: id, parent: parent, environment: env)
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

    private func process(_ file: inout UploadFile, jobID: UUID, parent: RemoteReference, environment env: UploadEnvironment) async throws {
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
                case .replace: throw UploadCoordinatorError.unsafeReplacement
                case .keepBoth:
                    let used = Set(entries.map { LocalPath.key($0.name) })
                    var number = 1; var candidate = LocalPath.numbered(original, number)
                    while used.contains(LocalPath.key(candidate)) { number += 1; candidate = LocalPath.numbered(original, number) }
                    file.remoteName = candidate
                }
            } else { file.remoteName = original }
            try await saveFile(file)
        }
        try Task.checkCancellation()
        if file.isDirectory {
            try Task.checkCancellation()
            let commit = UploadCommit(kind: .createDirectory)
            file.commits.append(commit); file.phase = .committing; try await saveFile(file)
            let reference = try await env.createDirectory(parent, file.remoteName!)
            file.remoteReference = reference; file.commits[file.commits.count - 1].status = .confirmed
            file.commits[file.commits.count - 1].finalObject = reference; file.phase = .committing
            try await saveFile(file)
            try await refreshRemoteName(&file, parent: parent, environment: env)
            file.phase = .completed; try await saveFile(file)
            return
        }
        let localURL: URL
        if let bookmark = file.source.bookmark { localURL = try UploadSource.resolve(bookmark: bookmark) }
        else { localURL = file.source.url }
        let accessed = localURL.startAccessingSecurityScopedResource()
        defer { if accessed { localURL.stopAccessingSecurityScopedResource() } }
        if file.preparation == nil {
            file.phase = .preparing; try await saveFile(file)
            let fingerprint = try await UploadSource.fingerprint(of: localURL, chunkSize: 4 * 1024 * 1024)
            guard fingerprint.identity.size == file.source.size else { throw UploadSourceError.changed(localURL.path) }
            if let identity = file.source.resourceIdentifier,
               try JSONDecoder().decode(UploadSourceIdentity.self, from: identity) != fingerprint.identity {
                throw UploadSourceError.changed(localURL.path)
            }
            file.expectation = try IntegrityExpectation(algorithm: .sha256, digest: fingerprint.sha256, origin: .localOriginal, size: file.source.size)
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
        try Task.checkCancellation()
        if prepared.isInstant, let reference = prepared.remoteReference {
            file.remoteReference = reference; file.phase = .verifying; try await saveFile(file)
        } else {
            file.phase = .uploading; try await saveFile(file)
            let fileID = file.id
            let receipts = try await UploadEngine(destination: env.destination, budget: budget).upload(localURL: localURL, prepared: prepared, receipts: file.parts,
                onReceipt: { [weak self] receipt in
                    guard let self else { throw CancellationError() }
                    try await self.received(receipt, fileID: fileID, jobID: jobID)
                })
            file = try await store.loadFile(id: file.id, in: jobs[jobID]!)
            try Task.checkCancellation()
            let commit = UploadCommit(kind: .merge)
            file.commits.append(commit); file.phase = .committing; try await saveFile(file)
            let reference = try await env.destination.complete(prepared, receipts: receipts)
            file.remoteReference = reference; file.commits[file.commits.count - 1].status = .confirmed
            file.commits[file.commits.count - 1].finalObject = reference; file.phase = .verifying
            try await saveFile(file)
        }
        try await refreshRemoteName(&file, parent: parent, environment: env)
        try await verify(&file, environment: env)
    }

    /// 只对明确未创建会话的名称冲突重选，复用原始指纹；已持久化 preparation 永远不换名重建。
    private func prepare(_ file: inout UploadFile, fingerprint: UploadSourceFingerprint, parent: RemoteReference,
                         environment env: UploadEnvironment) async throws -> Bool {
        let jobID = file.jobID
        var rejectedNames: Set<String> = []
        for attempt in 0...3 {
            try Task.checkCancellation()
            do {
                _ = try await env.destination.prepare(name: file.remoteName!, target: parent, source: fingerprint, fileID: file.id,
                    onPrepared: { [weak self] prepared in
                        guard let self else { throw CancellationError() }
                        try await self.prepared(prepared, jobID: jobID)
                    })
                return true
            } catch UploadDestinationError.nameConflict {
                guard let job = jobs[jobID] else { throw UploadCoordinatorError.missingJob }
                file = try await store.loadFile(id: file.id, in: job)
                guard file.preparation == nil else { throw UploadDestinationError.nameConflict }
                switch job.conflictPolicy {
                case .skip:
                    file.phase = .skipped; try await saveFile(file); return false
                case .replace: throw UploadCoordinatorError.unsafeReplacement
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

    private func inspect(_ file: inout UploadFile, parent: RemoteReference, environment env: UploadEnvironment) async throws {
        for index in file.commits.indices where file.commits[index].status == .pending {
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
        throw UploadDestinationError.remoteResultUnconfirmed
    }

    private func verify(_ file: inout UploadFile, environment env: UploadEnvironment) async throws {
        guard let reference = file.remoteReference, let expectation = file.expectation, expectation.algorithm == .sha256 else {
            throw UploadDestinationError.invalidPreparation
        }
        file.phase = .verifying; file.failedPhase = nil; file.error = nil; try await saveFile(file)
        let size = file.source.size
        let record = try await integrity.verify(account: env.destination.account, reference: reference,
            expectedSHA256: expectation.digest, size: size, remoteVersion: expectation.remoteVersion, uploadFileID: file.id,
            resolve: { try await env.resolve(reference, size) })
        do { try await integrityStore.save(record) }
        catch { throw UploadCoordinatorError.persistence(error.localizedDescription) }
        file.integrityRecordID = record.id
        guard record.status == .verified else { try await saveFile(file); throw UploadCoordinatorError.mismatch }
        file.phase = .completed; try await saveFile(file)
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

    private func prepared(_ prepared: PreparedUpload, jobID: UUID) async throws {
        guard let job = jobs[jobID], prepared.account == job.account else { throw UploadDestinationError.otherAccount }
        var file = try await store.loadFile(id: prepared.fileID, in: job)
        file.preparation = prepared
        try await saveFile(file)
    }

    private func received(_ receipt: UploadPartReceipt, fileID: UUID, jobID: UUID) async throws {
        guard let job = jobs[jobID] else { throw UploadCoordinatorError.missingJob }
        var file = try await store.loadFile(id: fileID, in: job)
        guard !file.parts.contains(where: { $0.index == receipt.index }) else { throw UploadDestinationError.invalidReceipt }
        file.parts.append(receipt); try await saveFile(file)
    }

    /// 文件状态先落盘，聚合随后保存；恢复时可从每文件检查点重建聚合。
    private func saveFile(_ file: UploadFile) async throws {
        guard let job = jobs[file.jobID] else { throw UploadCoordinatorError.missingJob }
        do {
            let previous = try await store.loadFile(id: file.id, in: job)
            try await store.saveFile(file, in: job)
            let delta = confirmedBytes(file) - confirmedBytes(previous)
            jobs[file.jobID]!.completedBytes = min(jobs[file.jobID]!.totalBytes, max(0, jobs[file.jobID]!.completedBytes + delta))
            jobs[file.jobID]!.completedCount += (file.phase == .completed ? 1 : 0) - (previous.phase == .completed ? 1 : 0)
            jobs[file.jobID]!.failedCount += (file.phase == .failed ? 1 : 0) - (previous.phase == .failed ? 1 : 0)
            jobs[file.jobID]!.skippedCount += (file.phase == .skipped ? 1 : 0) - (previous.phase == .skipped ? 1 : 0)
            if !jobs[file.jobID]!.isPaused && !jobs[file.jobID]!.cancellationRequested {
                jobs[file.jobID]!.phase = file.phase.isTerminal ? .queued : file.phase
            }
            try await persistJob(file.jobID)
        } catch let error as UploadCoordinatorError { throw error }
        catch { throw UploadCoordinatorError.persistence(error.localizedDescription) }
    }

    private func confirmedBytes(_ file: UploadFile) -> Int64 {
        if file.isDirectory || file.phase == .skipped { return 0 }
        if file.phase == .completed || file.remoteReference != nil { return file.source.size }
        guard let prepared = file.preparation else { return 0 }
        let pending = prepared.pendingParts.reduce(Int64(0)) { $0 + min(prepared.partSize, prepared.source.identity.size - Int64($1) * prepared.partSize) }
        return prepared.source.identity.size - pending + file.parts.reduce(0) { $0 + $1.length }
    }

    private func rebuildAggregate(_ id: UUID) async throws {
        guard let job = jobs[id] else { throw UploadCoordinatorError.missingJob }
        var completed = 0, failed = 0, skipped = 0
        var bytes: Int64 = 0
        var firstFailure: String?
        for fileID in job.fileIDs {
            let file = try await store.loadFile(id: fileID, in: job)
            bytes += confirmedBytes(file)
            if file.phase == .completed { completed += 1 }
            if file.phase == .failed {
                failed += 1
                if firstFailure == nil {
                    firstFailure = "\(file.relativePath)：\(file.error ?? "上传失败，未记录具体原因")"
                }
            }
            if file.phase == .skipped { skipped += 1 }
        }
        jobs[id]!.completedBytes = bytes; jobs[id]!.completedCount = completed
        jobs[id]!.failedCount = failed; jobs[id]!.skippedCount = skipped
        if let firstFailure { jobs[id]!.error = "\(failed) 项失败：\(firstFailure)" }
        try await persistJob(id)
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
        let active = !workers.isEmpty
        guard active != lastActivity else { return }
        lastActivity = active
        for observer in activityObservers.values { observer.yield(active) }
    }
}
