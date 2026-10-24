import DownloadKit
import Foundation
import Observation
import os

/// 一个任务的下载进度汇总。
public struct JobProgress: Sendable, Hashable {
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double

    public init(receivedBytes: Int64, totalBytes: Int64, bytesPerSecond: Double) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    public var fractionCompleted: Double {
        totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0
    }

    public var remainingTime: Duration? {
        guard bytesPerSecond > 0, totalBytes > receivedBytes else { return nil }
        return .seconds(Double(totalBytes - receivedBytes) / bytesPerSecond)
    }
}

/// 推进任务。分享任务：建任务子目录 → 转存 → 列出文件 → 下载 → 清理。网盘任务：列出文件（准备）→ 下载。
/// 它也保存任务列表，并在启动时恢复任务。
///
/// 网盘任务的源文件是用户自己的文件。对网盘任务不调用 `Netdisk.delete`：删除只经过 `deleteJobDirectory(of:using:)`。
///
/// 同一任务对下载引擎的操作（加入、暂停、继续）按顺序执行，每个操作执行时重新读取任务的当前状态，
/// 所以暂停和继续交错时，引擎中的状态最终和任务的 `isPaused` 一致。
@MainActor @Observable
public final class JobCoordinator {
    /// 新任务在前。
    public private(set) var jobs: [Job] = []
    /// 引擎中文件下载的最新状态，键是文件下载 id。界面不直接观察它（进度每 0.5 秒变化一次），
    /// 而是观察 `activity(of:)` 和 `activity(ofFile:)`。
    @ObservationIgnored public private(set) var downloads: [String: DownloadSnapshot] = [:]
    public private(set) var settings: FerrySettings
    /// 新任务的下载目录。已有任务使用创建时记录的目录。
    public var downloadFolder: DownloadFolder
    /// 每家当前会话分别路由，任务不会随界面筛选或另一家换号改绑。
    public var netdisks: [Provider: any Netdisk] = [:] {
        didSet {
            for provider in Provider.allCases {
                guard let previous = oldValue[provider], previous !== netdisks[provider] else { continue }
                // 撤销旧会话的准备任务，URLSession 请求及后续写请求继承取消状态。
                for job in jobs where job.provider == provider && job.phase == .transferring {
                    tasks[job.id]?.cancel()
                    update(job.id) {
                        $0.phase = .failed(.transfer)
                        $0.error = "账号会话已变化，请在原账号下重试，已记录的转存不会重复提交。"
                    }
                }
                save()
            }
        }
    }
    public var accountNames: [Provider: String] = [:]
    public private(set) var removalProblems: [String] = []
    /// 启动时任务列表无法读取的说明。界面显示它，用户关闭后清空。
    public private(set) var loadWarning: String?
    public private(set) var restorationProblem: String?
    /// `start()` 完成前为 false。在此之前，任务操作等待它完成。
    public private(set) var isStarted = false
    /// 正在移除的任务。移除完成前它们仍在 `jobs` 中，但不再接受操作。
    public private(set) var removingJobs: Set<Job.ID> = []
    @ObservationIgnored public var onJobCompleted: ((Job) -> Void)?
    @ObservationIgnored public var onRunningChanged: ((Bool) -> Void)?
    @ObservationIgnored private var runningFileIDs: Set<String> = []
    /// 测试用：每个文件下载加入引擎之前调用。
    @ObservationIgnored var willEnqueue: (@MainActor (JobFile) async -> Void)?

    @ObservationIgnored private let engine: DownloadEngine
    @ObservationIgnored private let store: JobStore
    @ObservationIgnored private let baseConfiguration: DownloadConfiguration
    @ObservationIgnored private let folderAccess: any DownloadFolderAccess
    /// 把一个文件或目录移到废纸篓。测试用它代替系统的废纸篓。
    @ObservationIgnored private let trashItem: @Sendable (URL) throws -> Void
    /// 已取得访问权限的任务下载目录。任务完成或移除后交回。
    @ObservationIgnored private var openedFolders: [UUID: OpenedFolder] = [:]
    /// 每个任务的转存或收尾任务。
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// 每个任务最后一个引擎操作。新的操作等它结束后再执行。
    @ObservationIgnored private var lanes: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var reconciling: Set<UUID> = []
    @ObservationIgnored private var finishing: Set<UUID> = []
    @ObservationIgnored private var startWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private let logger = Logger(subsystem: "Ferry", category: "jobs")
    /// 读取任务列表之前不写入，避免覆盖还没读取的文件。
    @ObservationIgnored private var hasLoaded = false
    /// 任务列表无法读取、也无法备份时为 false：这次启动不写入，保留原文件。
    @ObservationIgnored private var canSave = true
    /// 进度类变化（文件下载完成）延迟这么久再合并保存。阶段变化立即保存。
    @ObservationIgnored var saveDelay: Duration = .seconds(1)
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var isShuttingDown = false
    /// 完成状态写入任务列表后，要从引擎取消的文件下载。
    @ObservationIgnored private var cancelAfterSave: [String] = []
    /// 测试用：写入任务列表的次数。
    @ObservationIgnored private(set) var saveCount = 0
    /// 文件下载 id → (任务 id, 文件下标)。任务列表或文件列表变化后重建。
    @ObservationIgnored private var fileLocations: [String: (job: UUID, file: Int)] = [:]
    @ObservationIgnored private var jobIndices: [UUID: Int] = [:]
    /// 每个任务的计数。和索引一起重建，文件下载变化时增量更新（见 `changeFile`）。
    @ObservationIgnored private var tallies: [UUID: JobTally] = [:]
    @ObservationIgnored private var isIndexStale = true
    /// 测试用：每次更新计数后，从头重新计算并比较，不一致时调用。为 nil 时不比较。
    @ObservationIgnored var tallyMismatchHandler: ((String) -> Void)?
    @ObservationIgnored private var jobActivities: [UUID: JobActivity] = [:]
    @ObservationIgnored private var fileActivities: [String: FileActivity] = [:]
    @ObservationIgnored private var changedJobs: Set<UUID> = []
    @ObservationIgnored private var isActivityUpdateScheduled = false

    /// - Parameter baseConfiguration: 设置不覆盖的下载参数（分片大小、重试等）。
    public init(engine: DownloadEngine, store: JobStore, settings: FerrySettings, downloadFolder: DownloadFolder,
                folderAccess: any DownloadFolderAccess = SecurityScopedFolderAccess(),
                trashItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                baseConfiguration: DownloadConfiguration = DownloadConfiguration()) {
        self.engine = engine
        self.store = store
        self.settings = settings
        self.downloadFolder = downloadFolder
        self.folderAccess = folderAccess
        self.trashItem = trashItem
        self.baseConfiguration = baseConfiguration
        let events = engine.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    // MARK: - 启动与退出

    /// 读取任务列表，取得未完成任务的下载目录的访问权限，然后恢复引擎中的文件下载。
    public func start() async {
        guard !hasLoaded else { return }
        defer {
            isStarted = true
            let waiters = startWaiters
            startWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        var loaded: [Job]
        var isLoaded = true
        do {
            loaded = try store.load()
        } catch {
            logger.error("cannot read jobs: \(error.localizedDescription)")
            loaded = []
            isLoaded = false
            if let backup = store.moveAsideUnreadableFile() {
                loadWarning = "无法读取任务列表，原文件已备份为“\(backup.lastPathComponent)”。之前的下载进度保留在磁盘上，这次启动不继续也不删除它们。"
            } else {
                canSave = false
                loadWarning = "无法读取任务列表。这次启动不修改任务列表文件，之前的下载进度保留在磁盘上。"
            }
        }
        for index in loaded.indices where loaded[index].phase == .transferring {
            loaded[index].phase = .failed(.transfer)
            loaded[index].error = loaded[index].link != nil ? "应用退出时转存没有完成。" : "应用退出时准备没有完成。"
        }
        // 启动完成前添加的任务排在前面。
        jobs += loaded
        invalidateIndex()
        hasLoaded = true
        // 旧版本可能静默覆盖远端 MD5；先撤回错误校验状态，再恢复引擎，避免旧快照直接开跑。
        for job in jobs { _ = failConflictingIntegrity(of: job.id) }

        await engine.updateConfiguration(settings.downloadConfiguration(base: baseConfiguration))
        // 任务列表读不出来时，不知道引擎中的文件下载属于谁。不恢复它们，也不取消它们。
        guard isLoaded else {
            save()
            return
        }
        // 引擎恢复的文件下载要写入这些目录，所以先取得访问权限。
        for job in jobs where job.phase != .completed {
            do {
                _ = try folderURL(for: job.id)
            } catch {
                if job.phase == .downloading {
                    fail(job.id, step: .download, error)
                } else {
                    update(job.id) { $0.error = Self.message(for: error) }
                }
            }
        }
        let restored: [DownloadSnapshot]
        do {
            var contexts: [String: Data] = [:]
            var connections: [String: Int] = [:]
            var pausedIDs = Set<String>()
            for job in jobs {
                if job.isPaused || job.files.contains(where: { Self.integrityConflict(of: $0) != nil }) {
                    pausedIDs.formUnion(job.files.map(\.id))
                }
                guard let account = job.accountKey else { continue }
                for file in job.files {
                    let reference = file.remoteReference ?? .baidu(path: file.remotePath, fsID: 0)
                    contexts[file.id] = try DownloadContext(account: account, reference: reference, size: file.size, md5: file.md5).encoded()
                    connections[file.id] = settings.connections(for: job.provider)
                }
            }
            restored = try await engine.restore(contexts: contexts, pausedIDs: pausedIDs, connections: connections)
        } catch {
            logger.error("cannot restore downloads: \(error.localizedDescription)")
            restorationProblem = "下载进度恢复失败，原文件和分片已保留。请检查存储权限后重新启动。"
            loadWarning = restorationProblem
            for job in jobs where job.phase == .downloading {
                update(job.id) { $0.error = restorationProblem; $0.isPaused = true }
            }
            save()
            return
        }
        var finished: [String] = []
        for snapshot in restored {
            guard locate(snapshot.id) != nil else {
                await engine.cancel(id: snapshot.id)
                continue
            }
            if case .completed(let url) = snapshot.state {
                // 上次完成后、写入任务列表前应用退出了。
                recordCompletion(of: snapshot.id, at: url, evidence: snapshot)
                finished.append(snapshot.id)
            } else {
                setSnapshot(snapshot.id, snapshot)
            }
        }
        save()
        // 完成状态已写入任务列表，引擎不用再保留它们。
        for id in finished {
            await engine.cancel(id: id)
        }
        // 文件列表已保存、但还没交给引擎的文件下载重新加入；任务没暂停时，暂停的文件下载继续。
        for job in jobs where job.phase == .downloading {
            await serially(job.id) { await self.continueDownloads(job.id, resumingFailed: false) }
            evaluate(job.id)
        }
        save()
    }

    public func dismissLoadWarning() {
        loadWarning = nil
    }

    #if DEBUG
    /// 截图用：代替 `start()`，显示给定的任务和文件下载状态。不读取也不保存任务列表，不交给引擎。
    public func showDemo(jobs: [Job], downloads: [DownloadSnapshot]) {
        guard !hasLoaded else { return }
        hasLoaded = true
        canSave = false
        self.jobs = jobs
        invalidateIndex()
        for snapshot in downloads {
            setSnapshot(snapshot.id, snapshot)
        }
        isStarted = true
    }
    #endif

    /// 应用退出前调用：停止下载，把已完成的文件下载记入任务，然后保存。
    public func shutdown() async {
        isShuttingDown = true
        let running = Array(tasks.values)
        running.forEach { $0.cancel() }
        for task in running { await task.value }
        tasks = [:]
        await engine.shutdown()
        for snapshot in await engine.snapshots() {
            if case .completed(let url) = snapshot.state {
                recordCompletion(of: snapshot.id, at: url, evidence: snapshot)
            }
        }
        save()
        eventTask?.cancel()
        eventTask = nil
        runningFileIDs = []
        onRunningChanged?(false)
        for id in Array(openedFolders.keys) { closeFolder(of: id) }
    }

    /// 两家当前连接数同步到已排队、运行及暂停的下载，统一等待旧连接收尾后生效。
    public func updateSettings(_ settings: FerrySettings) async {
        self.settings = settings
        let connections = Dictionary(uniqueKeysWithValues: jobs.flatMap { job in
            job.files.filter { !$0.isCompleted }.map { ($0.id, settings.connections(for: job.provider)) }
        })
        await engine.updateConfiguration(settings.downloadConfiguration(base: baseConfiguration), connections: connections)
    }

    // MARK: - 任务操作

    /// 创建任务并开始转存。`session` 是添加链接时打开的分享会话。
    /// - Parameter downloadFolder: 用户为这个任务选择的下载目录。nil 时使用 `self.downloadFolder`（设置中的下载目录）。
    @discardableResult
    public func addJob(session: DiskShareSession, entries: [RemoteEntry], downloadFolder: DownloadFolder? = nil) -> Job {
        var job = Job(link: session.link, password: session.password, entries: entries, transferFolder: settings.transferFolder(for: session.account.provider))
        job.downloadFolder = downloadFolder ?? self.downloadFolder
        job.accountKey = session.account
        job.accountName = accountNames[session.account.provider]
        jobs.insert(job, at: 0)
        invalidateIndex()
        save()
        startTransfer(job.id)
        return job
    }

    /// 创建网盘任务并开始准备：列出勾选的目录，然后直接下载。不转存，也不修改网盘中的文件。
    /// - Parameters:
    ///   - accountUK: 勾选的条目所在的网盘的账号。它不是当前账号时，任务按另一个账号的任务处理，不列出也不下载。
    ///   - downloadFolder: 用户为这个任务选择的下载目录。nil 时使用 `self.downloadFolder`（设置中的下载目录）。
    @discardableResult
    public func addNetdiskJob(entries: [RemoteEntry], account: AccountKey, downloadFolder: DownloadFolder? = nil) -> Job {
        var job = Job(netdiskEntries: entries)
        job.downloadFolder = downloadFolder ?? self.downloadFolder
        job.accountKey = account
        job.accountName = accountNames[account.provider]
        jobs.insert(job, at: 0)
        invalidateIndex()
        save()
        startTransfer(job.id)
        return job
    }

    /// 创建带用户确认摘要的新网盘下载；基准按账号、真实对象及大小绑定，不能按同名猜测。
    @discardableResult
    public func addNetdiskJob(entries: [RemoteEntry], account: AccountKey, downloadFolder: DownloadFolder? = nil,
                              integrityBindings: [DownloadIntegrityBinding]) throws -> Job {
        for binding in integrityBindings {
            try binding.validate()
            guard binding.account == account else { throw CoordinatorError.otherAccount }
        }
        guard Set(integrityBindings.map(\.reference)).count == integrityBindings.count else {
            throw UploadRecordError.invalid("同一下载文件不能绑定多份内容基准")
        }
        var job = Job(netdiskEntries: entries)
        job.downloadFolder = downloadFolder ?? self.downloadFolder
        job.accountKey = account
        job.accountName = accountNames[account.provider]
        job.downloadIntegrityBindings = integrityBindings
        jobs.insert(job, at: 0)
        invalidateIndex()
        save()
        startTransfer(job.id)
        return job
    }

    public func pause(_ id: Job.ID) async {
        await waitUntilStarted()
        guard let job = activeJob(id), job.phase == .downloading, !job.isPaused else { return }
        update(id) { $0.isPaused = true }
        save()
        await serially(id) { await self.pauseDownloads(id) }
    }

    public func resume(_ id: Job.ID) async {
        await waitUntilStarted()
        guard let job = activeJob(id), job.phase == .downloading, job.isPaused else { return }
        guard !failConflictingIntegrity(of: id) else { return }
        update(id) { $0.isPaused = false }
        save()
        await serially(id) { await self.continueDownloads(id, resumingFailed: false) }
        evaluate(id)
    }

    public func retry(_ id: Job.ID) async {
        await waitUntilStarted()
        guard let job = activeJob(id), case .failed(let step) = job.phase else { return }
        switch step {
        case .transfer:
            update(id) {
                $0.phase = .transferring
                $0.error = nil
                $0.files = []
            }
            invalidateIndex()
            markChanged(id)
            save()
            // 重用已记录的目录和回执；结果不明时不会重复提交。网盘任务只重新列出。
            startTransfer(id)
        case .download:
            guard !failConflictingIntegrity(of: id) else { return }
            update(id) {
                $0.phase = .downloading
                $0.error = nil
                $0.isPaused = false
                for index in $0.files.indices where !$0.files[index].isCompleted && $0.files[index].integrityExpectation != nil {
                    $0.files[index].integrityStatus = .pending
                }
            }
            save()
            await serially(id) { await self.continueDownloads(id, resumingFailed: true) }
            evaluate(id)
        }
    }

    /// 移除任务，取消没有完成的文件下载。`trashingFiles` 为 true 时把已下载的文件移到废纸篓（见 `JobFileTrash`），
    /// 否则它们留在本地。
    /// - Returns: 没能移到废纸篓的文件或目录。
    @discardableResult
    public func remove(_ id: Job.ID, trashingFiles: Bool = false, cleanupConfirmed: Bool? = nil) async -> [URL] {
        await waitUntilStarted()
        guard job(id) != nil, !removingJobs.contains(id) else { return [] }
        removingJobs.insert(id)
        defer { removingJobs.remove(id) }
        if let task = tasks.removeValue(forKey: id) {
            task.cancel()
            await task.value
        }
        // 等已开始的引擎操作结束。之后的操作看到任务正在移除，不再修改引擎。
        await serially(id) {}
        lanes[id] = nil
        // 转存可能在结束前写入了文件列表，所以重新读取任务。
        guard let pending = job(id) else { return [] }
        for file in pending.files {
            if let completedURL = await engine.cancel(id: file.id) {
                recordCompletion(of: file.id, at: completedURL)
            }
        }
        // 取消收尾期间仍可能完成其他文件；合并引擎确认路径后再决定本地文件范围。
        guard let job = job(id) else { return [] }
        var failed: [URL] = []
        if trashingFiles {
            // 已完成的任务已经交回了下载目录的访问权限，重新取得。取不到时移动失败，如实返回。
            _ = try? folderURL(for: id)
            let trashItem = trashItem
            failed = await Task.detached { JobFileTrash.trash(job, using: trashItem) }.value
        }
        jobs.removeAll { $0.id == id }
        invalidateIndex()
        jobActivities[id] = nil
        // 引擎事件流可能尚未消费 removed，返回前同步清除快照与实际运行标记。
        for file in job.files {
            setSnapshot(file.id, nil)
            fileActivities[file.id] = nil
        }
        save()
        closeFolder(of: id)
        let verifiedForAutomaticCleanup = !job.files.isEmpty && job.files.allSatisfy { $0.integrityStatus == .verified && $0.integrityExpectation != nil }
        let shouldCleanup = cleanupConfirmed ?? (settings.cleanupAfterDownload(for: job.provider) && verifiedForAutomaticCleanup)
        if shouldCleanup, job.hasJobDirectory, !job.isCleanedUp {
            do {
                guard job.transferProgress?.completed == true else { throw TransferCheckError.unconfirmedTransfer }
                try await deleteJobDirectory(of: job, using: disk(for: job))
            } catch {
                logger.error("cannot delete \(job.remoteDirectory): \(error.localizedDescription)")
                removalProblems.append("\(job.provider.title) · \(job.accountName ?? job.accountKey?.accountID ?? "未记录账号") · \(job.remoteDirectory)：转存目录未清理，\(Self.message(for: error))")
            }
        }
        return failed
    }

    public func progress(of job: Job) -> JobProgress {
        var received: Int64 = 0
        var speed = 0.0
        for file in job.files {
            if file.isCompleted {
                received += file.size
            } else if let snapshot = downloads[file.id] {
                received += snapshot.receivedBytes
                speed += snapshot.bytesPerSecond
            }
        }
        return JobProgress(receivedBytes: received, totalBytes: job.totalBytes, bytesPerSecond: speed)
    }

    // MARK: - 转存和准备

    /// 开始任务的第一步：分享任务转存，网盘任务准备。
    private func startTransfer(_ id: Job.ID) {
        tasks[id] = Task {
            await waitUntilStarted()
            await transfer(id)
        }
    }

    /// 按固定账号准备文件，然后交给共享下载引擎。
    private func transfer(_ id: Job.ID) async {
        guard let job = activeJob(id) else { return }
        do {
            try persistRequired()
            // 先确认下载目录可以写入，再操作网盘。
            _ = try folderURL(for: id)
            let netdisk = try disk(for: job)
            var files: [JobFile]
            var warning: String?
            switch job.source {
            case .share(let link, let password, let entries):
                let remoteFiles = try await transferShare(job, link: link, password: password, entries: entries,
                                                          netdisk: netdisk)
                if remoteFiles.isEmpty { warning = "勾选的目录中没有文件，不需要下载。" }
                files = try Self.jobFiles(for: remoteFiles)
            case .netdisk(let entries):
                files = try Self.jobFiles(for: await netdisk.files(in: entries))
                // 网盘的列表没有转存延迟，不用像分享任务那样再检查一次。
                if files.isEmpty { warning = "勾选的目录中没有文件，不需要下载。" }
            }
            if let bindings = job.downloadIntegrityBindings {
                for binding in bindings {
                    try binding.validate()
                    guard binding.account == job.accountKey,
                          let index = files.firstIndex(where: { $0.remoteReference == binding.reference }),
                          files[index].size == binding.expectation.size else {
                        throw UploadRecordError.invalid("下载校验依据未匹配本次账号、文件或大小")
                    }
                    files[index].integrityExpectation = binding.expectation
                    files[index].integrityStatus = .pending
                }
            }
            try Task.checkCancellation()
            try checkCurrentAccount(job, expected: netdisk.account)
            guard activeJob(id) != nil else { return }
            update(id) {
                $0.files = files
                $0.phase = .downloading
                $0.isCleanedUp = false
                $0.warning = warning
            }
            invalidateIndex()
            markChanged(id)
            save()
            await serially(id) { await self.continueDownloads(id, resumingFailed: false) }
            evaluate(id)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            fail(id, step: .transfer, error)
        }
    }

    /// 先保存目录、提交意图和服务端回执；不确定的提交不能自动重复。
    private func transferShare(_ original: Job, link: DiskShareLink, password: String?, entries: [RemoteEntry],
                               netdisk: any Netdisk) async throws -> [PreparedFile] {
        let id = original.id
        var ownedShare: DiskShareSession?
        defer {
            if let ownedShare { Task { await netdisk.releaseShare(ownedShare) } }
        }
        var directory = original.transferDirectory
        if directory == nil {
            guard original.remoteDirectory == RemotePath.normalized(original.remoteDirectory),
                  RemotePath.components(of: original.remoteDirectory, omittingEmpty: true).last == Job.shortID(id) else {
                throw TransferCheckError.missingJobDirectory
            }
            if original.accountKey == nil { throw CoordinatorError.unknownAccount }
            directory = try await netdisk.createTransferDirectory(parentPath: RemotePath.parent(of: original.remoteDirectory), name: Job.shortID(id))
            try checkCurrentAccount(original, expected: netdisk.account)
            update(id) { $0.transferDirectory = directory }
            try persistRequired()
        }
        guard let directory else { throw TransferCheckError.missingJobDirectory }
        var progress = original.transferProgress
        var manifest = original.transferManifest
        if progress?.completed != true, progress?.needsSubmission ?? true {
            // 明确尚未提交的批次才获取新的提交令牌；已有回执不再重复提交。
            let share = try await netdisk.openShare(link, password: password)
            ownedShare = share
            let pendingIDs = progress?.batches.map { Set($0.filter { !$0.submitted }.flatMap(\.entryIDs)) }
            let pending = pendingIDs.map { ids in entries.filter { ids.contains($0.id) } } ?? entries
            try await netdisk.prepareTransfer(share, entries: pending)
        }
        if manifest == nil {
            do {
                if ownedShare == nil, entries.contains(where: { entry in
                    entry.isDirectory || entry.relativeDirectory == nil && entry.reference.provider == .quark &&
                        progress?.batches?.contains(where: { $0.entryIDs.contains(entry.id) }) != true
                }) {
                    ownedShare = try await netdisk.openShare(link, password: password)
                }
                manifest = try await makeTransferManifest(selected: entries, progress: progress,
                                                        session: ownedShare, netdisk: netdisk)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                if progress?.submitted == true { throw TransferCheckError.unconfirmedManifest(error.localizedDescription) }
                throw error
            }
            try checkCurrentAccount(original, expected: netdisk.account)
            update(id) { $0.transferManifest = manifest }
            // 清单写盘失败时不允许提交，已收到的回执和清单仍留在内存供保存重试。
            try persistRequired()
        }
        if progress?.completed != true {
            try checkCurrentAccount(original, expected: netdisk.account)
            progress = try await netdisk.submitTransfer(ownedShare, entries: entries, to: directory, previous: progress) { [weak self] reported in
                guard let self else { throw CancellationError() }
                try await self.recordTransferProgress(reported, for: id, using: netdisk)
            }
        }
        guard progress?.completed == true else { throw TransferCheckError.unconfirmedTransfer }
        let children = try await netdisk.listDirectory(directory.reference)
        try netdisk.validateChildren(children, of: directory.reference)
        let files = try await netdisk.files(in: children)
        guard let manifest else { throw TransferCheckError.unconfirmedTransfer }
        try validateTransferredFiles(files, manifest: manifest)
        return files
    }

    /// 提交前仅读取所选子树，保存不含短期令牌的路径和大小；恢复时不重新读取源分享。
    private func makeTransferManifest(selected: [RemoteEntry], progress: TransferProgress?,
                                      session: DiskShareSession?, netdisk: any Netdisk) async throws -> [TransferManifestEntry] {
        var parents: [RemoteReference: String] = [:]
        for entry in selected {
            if let parent = entry.relativeDirectory { parents[entry.reference] = parent }
            else if let parent = progress?.batches?.first(where: { $0.entryIDs.contains(entry.id) })?.relativeDirectory {
                parents[entry.reference] = parent
            } else if entry.reference.provider == .baidu { parents[entry.reference] = "" }
        }
        // 旧夸克记录只保存 fid 时无法推断路径；仅此兼容分支扫描至所选身份全部找到。
        var unresolved = Set(selected.map(\.reference)).subtracting(parents.keys)
        if !unresolved.isEmpty {
            guard let session else { throw TransferCheckError.unconfirmedTransfer }
            var directories: [(RemoteEntry?, String)] = [(nil, "")]
            var visited = Set<RemoteReference>()
            while !unresolved.isEmpty, let (directory, parent) = directories.popLast() {
                try Task.checkCancellation()
                if let directory, !visited.insert(directory.reference).inserted { continue }
                for child in try await netdisk.listShare(session, directory: directory) {
                    if unresolved.remove(child.reference) != nil { parents[child.reference] = parent }
                    if child.isDirectory { directories.append((child, parent.isEmpty ? child.name : parent + "/" + child.name)) }
                }
            }
            guard unresolved.isEmpty else { throw TransferCheckError.unconfirmedTransfer }
        }
        var pending: [(RemoteEntry, String)] = selected.map { entry in
            let parent = parents[entry.reference]!
            return (entry, parent.isEmpty ? entry.name : parent + "/" + entry.name)
        }
        var visited = Set<RemoteReference>()
        var expected: [String: Int64] = [:]
        while let (entry, path) = pending.popLast() {
            try Task.checkCancellation()
            guard LocalPath.isSafe(path), entry.size >= 0 else { throw TransferCheckError.unsafePath(path) }
            if entry.isDirectory {
                guard visited.insert(entry.reference).inserted else { continue }
                guard let session else { throw TransferCheckError.unconfirmedTransfer }
                for child in try await netdisk.listShare(session, directory: entry) {
                    guard !child.name.contains("/"), LocalPath.isSafe(child.name) else {
                        throw TransferCheckError.unsafePath(child.name)
                    }
                    pending.append((child, path + "/" + child.name))
                }
            } else { expected[path] = entry.size }
        }
        return expected.keys.sorted().map { TransferManifestEntry(relativePath: $0, size: expected[$0]!) }
    }

    /// 目标列表复用已完成的递归结果，与已保存清单核对；部分结果不进入下载或清理。
    private func validateTransferredFiles(_ files: [PreparedFile], manifest: [TransferManifestEntry]) throws {
        if files.isEmpty, !manifest.isEmpty { throw TransferCheckError.noFiles }
        var actual: [String: Int64] = [:]
        for file in files {
            guard actual.updateValue(file.entry.size, forKey: file.relativePath) == nil else {
                throw TransferCheckError.incompleteTransfer(file.relativePath)
            }
        }
        for entry in manifest where actual.removeValue(forKey: entry.relativePath) != entry.size {
            throw TransferCheckError.incompleteTransfer(entry.relativePath)
        }
        if let unexpected = actual.keys.sorted().first { throw TransferCheckError.incompleteTransfer(unexpected) }
    }

    /// 新意图或失败回执重置写盘失败时恢复原状态；新收到的回执则保留在内存供再次保存。
    private func recordTransferProgress(_ progress: TransferProgress, for id: Job.ID, using netdisk: any Netdisk) throws {
        guard let current = job(id) else { throw CancellationError() }
        let previous = current.transferProgress
        let isIntent = progress.introducesSubmissionIntent(comparedTo: previous)
        // 明确失败的空批次可回到未提交；写盘失败时仍须保留原回执供核对。
        let previousReceipts = Set((previous?.batches?.compactMap(\.taskID) ?? []) + [previous?.taskID].compactMap { $0 })
        let nextReceipts = Set((progress.batches?.compactMap(\.taskID) ?? []) + [progress.taskID].compactMap { $0 })
        let removesReceipt = !previousReceipts.isSubset(of: nextReceipts)
        if isIntent || removesReceipt { try checkCurrentAccount(current, expected: netdisk.account) }
        update(id) { $0.transferProgress = progress }
        do { try persistRequired() }
        catch {
            if isIntent || removesReceipt { update(id) { $0.transferProgress = previous } }
            throw error
        }
    }

    /// 校验并统一本地路径，保留每个文件的真实远端引用。
    static func jobFiles(for files: [PreparedFile]) throws -> [JobFile] {
        for file in files where !LocalPath.isSafe(file.relativePath) {
            throw TransferCheckError.unsafePath(file.relativePath)
        }
        return zip(files, LocalPath.deduplicated(files.map(\.relativePath))).map { file, path in
            var result = JobFile(remotePath: file.entry.reference.identifier, relativePath: path, size: file.entry.size)
            result.remoteReference = file.entry.reference
            result.md5 = file.entry.md5
            return result
        }
    }

    /// 清理只接受已记录且名称匹配任务 ID 的专用目录。
    private func deleteJobDirectory(of job: Job, using netdisk: any Netdisk) async throws {
        guard job.hasJobDirectory, job.transferProgress?.completed == true else { throw TransferCheckError.unconfirmedTransfer }
        try checkCurrentAccount(job, expected: netdisk.account)
        let directory: TransferDirectory
        if let recorded = job.transferDirectory { directory = recorded }
        else { directory = TransferDirectory(reference: .baidu(path: job.remoteDirectory, fsID: 0), name: Job.shortID(job.id)) }
        try await netdisk.deleteDirectory(directory)
    }

    // MARK: - 下载

    /// 在任务的引擎操作队列中执行 `operation`，等它结束后返回。
    private func serially(_ id: Job.ID, _ operation: @escaping @MainActor () async -> Void) async {
        let previous = lanes[id]
        let task = Task {
            await previous?.value
            await operation()
        }
        lanes[id] = task
        await task.value
    }

    /// 让引擎中的文件下载和任务一致：不在引擎中的加入引擎；任务没暂停时，暂停的继续。
    /// `resumingFailed` 为 true 时失败的也继续（重试）。每处理一个文件都重新读取任务，任务暂停、移除或失败时停止。
    private func continueDownloads(_ id: Job.ID, resumingFailed: Bool) async {
        guard let job = activeJob(id), job.phase == .downloading else { return }
        guard !failConflictingIntegrity(of: id) else { return }
        let files = job.files
        if files.contains(where: { !$0.isCompleted }) {
            do {
                _ = try folderURL(for: id)
            } catch {
                fail(id, step: .download, error)
                return
            }
        }
        for file in files where !file.isCompleted {
            guard !Task.isCancelled, let job = activeJob(id), job.phase == .downloading else { return }
            let state = await engine.snapshot(id: file.id)?.state
            do {
                switch state {
                case nil:
                    try await enqueue(file, of: id)
                case .paused where !job.isPaused:
                    await engine.resume(id: file.id)
                case .failed where resumingFailed && !job.isPaused:
                    await engine.resume(id: file.id)
                default:
                    continue
                }
            } catch {
                fail(id, step: .download, error)
                return
            }
            await refreshSnapshot(file.id)
        }
    }

    /// 事件稍后才到。先记下引擎的当前状态，随后的 `evaluate` 才不会按旧状态判断。
    private func refreshSnapshot(_ fileID: String) async {
        guard let snapshot = await engine.snapshot(id: fileID) else { return }
        if case .completed = snapshot.state { return }
        setSnapshot(fileID, snapshot)
    }

    /// 暂停任务的文件下载。任务在此期间被继续时停止。
    private func pauseDownloads(_ id: Job.ID) async {
        guard let files = activeJob(id)?.files else { return }
        for file in files where !file.isCompleted {
            guard activeJob(id)?.isPaused == true else { return }
            await engine.pause(id: file.id)
            await refreshSnapshot(file.id)
        }
    }

    /// 加入引擎前拒绝同算法校验依据冲突；加入期间任务被暂停时，立即暂停它。
    private func enqueue(_ file: JobFile, of id: Job.ID) async throws {
        await willEnqueue?(file)
        guard let job = activeJob(id) else { return }
        guard let account = job.accountKey else { throw CoordinatorError.unknownAccount }
        _ = try disk(for: job)
        guard let destination = LocalPath.destination(for: file.relativePath, in: try folderURL(for: id)) else {
            throw TransferCheckError.unsafePath(file.relativePath)
        }
        if let conflict = Self.integrityConflict(of: file) { throw UploadRecordError.invalid(conflict) }
        try await engine.enqueue(DownloadRequest(
            id: file.id,
            destination: destination,
            expectedSize: file.size,
            context: try DownloadContext(account: account, reference: file.remoteReference ?? .baidu(path: file.remotePath, fsID: 0), size: file.size, md5: file.md5).encoded(),
            connections: settings.connections(for: job.provider),
            expectedMD5: file.integrityExpectation?.algorithm == .md5 ? file.integrityExpectation?.digest : file.md5,
            expectedSHA256: file.integrityExpectation?.algorithm == .sha256 ? file.integrityExpectation?.digest : nil
        ))
        if activeJob(id)?.isPaused ?? false {
            await engine.pause(id: file.id)
        }
    }

    private func handle(_ event: DownloadEvent) {
        switch event {
        case .progress(let snapshot):
            guard locate(snapshot.id) != nil else { return }
            setSnapshot(snapshot.id, snapshot)
        case .stateChanged(let snapshot):
            guard let (jobIndex, _) = locate(snapshot.id) else { return }
            let jobID = jobs[jobIndex].id
            if case .completed(let url) = snapshot.state {
                recordCompletion(of: snapshot.id, at: url, evidence: snapshot)
                // 完成状态写入任务列表后，引擎才删除这个文件下载的状态。
                cancelAfterSave.append(snapshot.id)
                scheduleSave()
            }
            setSnapshot(snapshot.id, snapshot)
            evaluate(jobID)
        case .removed(let id):
            setSnapshot(id, nil)
        }
    }

    private func setSnapshot(_ fileID: String, _ snapshot: DownloadSnapshot?) {
        let wasRunning = !runningFileIDs.isEmpty
        if snapshot?.state == .running { runningFileIDs.insert(fileID) }
        else { runningFileIDs.remove(fileID) }
        if wasRunning != !runningFileIDs.isEmpty { onRunningChanged?(!runningFileIDs.isEmpty) }
        changeFile(fileID) { downloads[fileID] = snapshot }
        fileActivities[fileID]?.snapshot = snapshot
        if let snapshot, case .failed(.invalidResponse(let reason)) = snapshot.state,
           reason == "文件 MD5 与远端校验值不一致，请重新添加任务" || reason == "文件 SHA-256 与预期校验值不一致，请重新添加任务",
           let (jobIndex, fileIndex) = locate(fileID), jobs[jobIndex].files[fileIndex].integrityExpectation != nil {
            changeFile(fileID) { jobs[jobIndex].files[fileIndex].integrityStatus = .mismatch }
        }
    }

    /// 把引擎报告的最终路径记入任务。已经记入时不变。
    private func recordCompletion(of fileID: String, at url: URL, evidence: DownloadSnapshot? = nil) {
        guard let (jobIndex, fileIndex) = locate(fileID), jobs[jobIndex].files[fileIndex].localURL == nil else { return }
        let file = jobs[jobIndex].files[fileIndex]
        let expectation = file.integrityExpectation
        let verified: Bool
        if Self.integrityConflict(of: file) == nil,
           let expectation, let evidence, case .completed(let completedURL) = evidence.state, completedURL == url {
            switch expectation.algorithm {
            case .sha256: verified = evidence.expectedSHA256?.lowercased() == expectation.digest
            case .md5: verified = evidence.expectedMD5?.lowercased() == expectation.digest
            }
        } else { verified = false }
        changeFile(fileID) {
            jobs[jobIndex].files[fileIndex].localURL = url
            jobs[jobIndex].files[fileIndex].integrityStatus = verified ? .verified : .unavailable
            jobs[jobIndex].files[fileIndex].integrityVerifiedAt = verified ? .now : nil
        }
    }

    /// 同算法的有效完整摘要必须一致；未确认语义的 HTTP ETag 不参与这个判断。
    private static func integrityConflict(of file: JobFile) -> String? {
        guard let expectation = file.integrityExpectation, expectation.algorithm == .md5,
              let remoteMD5 = file.md5,
              IntegrityExpectation.isDigest(remoteMD5.lowercased(), algorithm: .md5),
              remoteMD5.lowercased() != expectation.digest.lowercased() else { return nil }
        return "指定的 MD5 与网盘文件摘要冲突，请核对文件版本或校验依据"
    }

    /// 不删除内容或分片；仅撤回冲突依据产生的旧 verified，并阻止恢复、继续及自动清理。
    @discardableResult
    private func failConflictingIntegrity(of id: Job.ID) -> Bool {
        guard let job = activeJob(id),
              let conflict = job.files.lazy.compactMap(Self.integrityConflict).first else { return false }
        update(id) {
            for index in $0.files.indices where Self.integrityConflict(of: $0.files[index]) != nil {
                // 两份基准相互矛盾不等于已证明实际内容不同，故标未验证并保留明确任务错误。
                $0.files[index].integrityStatus = .unavailable
                $0.files[index].integrityVerifiedAt = nil
            }
        }
        fail(id, step: .download, UploadRecordError.invalid(conflict))
        return true
    }

    /// 修改文件下载在 `downloads` 中的状态或它的 `localURL` 时都经过这里：所在任务的计数先减去这个文件原来的部分，
    /// 修改后再加上新的部分。不属于任何任务的文件下载不影响计数。
    private func changeFile(_ fileID: String, _ change: () -> Void) {
        // 先重建索引（同时重建计数），减去的才是修改前的部分。
        guard let location = locateIndexed(fileID), let jobIndex = jobIndices[location.job] else {
            change()
            return
        }
        tallies[location.job]?.remove(jobs[jobIndex].files[location.file], at: location.file, downloads[fileID])
        change()
        tallies[location.job]?.add(jobs[jobIndex].files[location.file], at: location.file, downloads[fileID])
        markChanged(location.job)
        verifyTally(of: location.job)
    }

    /// 根据文件下载的状态更新任务的阶段。
    private func evaluate(_ id: Job.ID) {
        guard let job = activeJob(id), job.phase == .downloading, !finishing.contains(id),
              let tally = tallies[id] else { return }
        let outcome = outcome(of: job, tally)
        if let handler = tallyMismatchHandler {
            let scanned = scannedOutcome(of: job)
            if outcome != scanned { handler("job \(id): outcome \(outcome), scanning gives \(scanned)") }
        }
        switch outcome {
        case .finish: finish(id)
        case .reconcile: reconcile(id)
        case .fail(let failure): fail(id, step: .download, failure)
        case .wait: break
        }
    }

    /// 任务下一步要做的事。只读计数，不遍历文件列表。
    private func outcome(of job: Job, _ tally: JobTally) -> Outcome {
        if tally.pendingCount == 0 { return .finish }
        guard !job.isPaused else { return .wait }
        // 任务没暂停，文件下载却暂停了（例如启动时恢复为暂停）。让它们继续，否则任务一直停在“下载中”。
        if tally.pausedCount > 0 { return .reconcile }
        // 还有文件下载没加入引擎（例如正在逐个加入）时，结果还没确定。
        guard tally.trackedCount == tally.pendingCount, tally.queuedCount == 0, tally.runningFiles.isEmpty,
              tally.failedCount > 0 else { return .wait }
        // 只在任务失败时遍历一次：失败后任务不再是“下载中”，不再到这里。
        return firstFailure(in: job).map(Outcome.fail) ?? .wait
    }

    /// 测试用：不用计数，遍历文件列表得出下一步。结果应和 `outcome(of:_:)` 相同。
    private func scannedOutcome(of job: Job) -> Outcome {
        let pending = job.files.filter { !$0.isCompleted }
        if pending.isEmpty { return .finish }
        guard !job.isPaused else { return .wait }
        let states = pending.compactMap { downloads[$0.id]?.state }
        if states.contains(.paused) { return .reconcile }
        guard states.count == pending.count, !states.contains(where: { $0 == .queued || $0 == .running }) else { return .wait }
        return firstFailure(in: job).map(Outcome.fail) ?? .wait
    }

    /// 按文件顺序，第一个失败的没完成的文件下载的原因。
    private func firstFailure(in job: Job) -> DownloadFailure? {
        job.files.lazy.filter { !$0.isCompleted }.compactMap { file -> DownloadFailure? in
            if case .failed(let failure) = self.downloads[file.id]?.state { failure } else { nil }
        }.first
    }

    private func reconcile(_ id: Job.ID) {
        guard reconciling.insert(id).inserted else { return }
        Task {
            await serially(id) { await self.continueDownloads(id, resumingFailed: false) }
            reconciling.remove(id)
            evaluate(id)
        }
    }

    /// 全部文件下载完成后，按设置清理，然后标记为已完成。清理失败只记录警告。
    private func finish(_ id: Job.ID) {
        finishing.insert(id)
        tasks[id] = Task {
            defer { finishing.remove(id) }
            // 网盘任务没有转存的文件，不清理。
            if let job = activeJob(id), settings.cleanupAfterDownload(for: job.provider), job.hasJobDirectory, !job.isCleanedUp {
                do {
                    // 先核对当前账号归属；这是本地检查，不为其他账号发起任何远端请求。
                    let netdisk = try disk(for: job)
                    guard !job.files.isEmpty, job.files.allSatisfy({ $0.integrityStatus == .verified && $0.integrityExpectation != nil }) else {
                        throw UploadRecordError.invalid("没有全部文件的可信内容校验结果，已保留转存文件")
                    }
                    try await deleteJobDirectory(of: job, using: netdisk)
                    update(id) { $0.isCleanedUp = true }
                } catch {
                    guard !Task.isCancelled else { return }
                    update(id) { $0.warning = "没有删除网盘中的转存文件：" + Self.message(for: error) }
                }
            }
            guard !Task.isCancelled, activeJob(id) != nil else { return }
            update(id) {
                $0.phase = .completed
                $0.isPaused = false
            }
            save()
            closeFolder(of: id)
            if let job = job(id) {
                onJobCompleted?(job)
            }
        }
    }

    /// 按任务归属取得会话，未知归属不会绑定当前登录用户。
    private func disk(for job: Job) throws -> any Netdisk {
        guard let disk = netdisks[job.provider] else { throw CoordinatorError.notLoggedIn }
        try checkCurrentAccount(job, expected: disk.account)
        return disk
    }

    private func checkCurrentAccount(_ job: Job, expected: AccountKey) throws {
        try Task.checkCancellation()
        guard let key = job.accountKey else { throw CoordinatorError.unknownAccount }
        guard key == expected, netdisks[job.provider]?.account == expected else { throw CoordinatorError.otherAccount }
    }

    public func belongsToOtherAccount(_ job: Job) -> Bool {
        guard let owner = job.accountKey, let current = netdisks[job.provider]?.account else { return false }
        return owner != current
    }

    func checkAccount(ofDownload id: String) throws {
        guard let (index, _) = locate(id) else { throw CoordinatorError.unknownAccount }
        _ = try disk(for: jobs[index])
    }

    public func dismissRemovalProblems() { removalProblems = [] }

    // MARK: - 下载目录

    /// 任务下载目录的当前位置。第一次调用时取得访问权限，直到任务完成或移除。
    /// 记录的 bookmark 不可用、但设置中的下载目录是同一位置时，改用设置中的 bookmark（用户重新选择了这个目录）。
    private func folderURL(for id: Job.ID) throws -> URL {
        if let opened = openedFolders[id] { return opened.url }
        guard let job = job(id) else { throw CancellationError() }
        let recorded = job.downloadFolder ?? downloadFolder
        var folder = recorded
        let opened: OpenedFolder
        do {
            opened = try folderAccess.open(recorded)
        } catch {
            guard recorded != downloadFolder, recorded.isSameLocation(as: downloadFolder),
                  let reopened = try? folderAccess.open(downloadFolder) else { throw error }
            folder = downloadFolder
            opened = reopened
        }
        if let renewed = opened.renewedBookmark {
            folder.bookmark = renewed
        }
        if folder != job.downloadFolder {
            update(id) { $0.downloadFolder = folder }
            save()
        }
        openedFolders[id] = opened
        return opened.url
    }

    private func closeFolder(of id: Job.ID) {
        if let opened = openedFolders.removeValue(forKey: id) {
            folderAccess.close(opened)
        }
    }

    // MARK: - 辅助

    private func waitUntilStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    private func fail(_ id: Job.ID, step: Job.Step, _ error: any Error) {
        guard activeJob(id) != nil else { return }
        update(id) {
            $0.phase = .failed(step)
            $0.error = Self.message(for: error)
            if step == .download, $0.hasJobDirectory {
                $0.warning = "下载未通过完整内容校验，已保留网盘中的转存文件。"
            }
        }
        save()
    }

    private func job(_ id: Job.ID) -> Job? {
        if isIndexStale { rebuildIndex() }
        return jobIndices[id].map { jobs[$0] }
    }

    /// 存在且没有正在移除的任务。
    private func activeJob(_ id: Job.ID) -> Job? {
        isShuttingDown || removingJobs.contains(id) ? nil : job(id)
    }

    private func update(_ id: Job.ID, _ body: (inout Job) -> Void) {
        if isIndexStale { rebuildIndex() }
        guard let index = jobIndices[id] else { return }
        body(&jobs[index])
        markChanged(id)
    }

    private func locate(_ fileID: String) -> (Int, Int)? {
        guard let location = locateIndexed(fileID), let jobIndex = jobIndices[location.job] else { return nil }
        return (jobIndex, location.file)
    }

    private func locateIndexed(_ fileID: String) -> (job: UUID, file: Int)? {
        if isIndexStale { rebuildIndex() }
        return fileLocations[fileID]
    }

    private func invalidateIndex() {
        isIndexStale = true
    }

    private func rebuildIndex() {
        fileLocations = [:]
        jobIndices = [:]
        tallies = [:]
        for (jobIndex, job) in jobs.enumerated() {
            jobIndices[job.id] = jobIndex
            for (fileIndex, file) in job.files.enumerated() {
                fileLocations[file.id] = (job.id, fileIndex)
            }
            tallies[job.id] = JobTally(files: job.files, downloads: downloads)
        }
        isIndexStale = false
    }

    /// 测试用：从头计算任务的计数，和增量维护的计数比较。`tallyMismatchHandler` 为 nil 时不计算。
    private func verifyTally(of id: Job.ID) {
        guard let handler = tallyMismatchHandler, let job = job(id) else { return }
        let expected = JobTally(files: job.files, downloads: downloads)
        if tallies[id] != expected {
            handler("job \(id): tally \(String(describing: tallies[id])), recomputed \(expected)")
        }
    }

    /// 立即写入任务列表，然后从引擎取消已记入任务的完成的文件下载。
    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard hasLoaded, canSave else { return }
        do {
            try store.save(jobs)
            saveCount += 1
        } catch {
            logger.error("cannot save jobs: \(error.localizedDescription)")
            return
        }
        let finished = cancelAfterSave
        cancelAfterSave = []
        if !finished.isEmpty {
            Task {
                for id in finished { await engine.cancel(id: id) }
            }
        }
    }

    /// 远端写操作前必须成功持久化；磁盘错误不能退化为仅记录日志后继续转存。
    private func persistRequired() throws {
        guard hasLoaded, canSave else { throw CocoaError(.fileWriteNoPermission) }
        pendingSave?.cancel()
        pendingSave = nil
        try store.save(jobs)
        saveCount += 1
    }

    /// 合并短时间内的多次变化，`saveDelay` 后写入一次。
    private func scheduleSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    // MARK: - 界面观察的进度

    /// 任务的汇总进度。每个任务一个对象，进度变化只让显示这个任务的视图刷新。
    public func activity(of id: Job.ID) -> JobActivity {
        if let activity = jobActivities[id] { return activity }
        let activity = JobActivity()
        refresh(activity, for: id)
        jobActivities[id] = activity
        return activity
    }

    /// 文件下载的状态。只有详情栏中的文件行观察它。
    public func activity(ofFile id: String) -> FileActivity {
        if let activity = fileActivities[id] { return activity }
        let activity = FileActivity(snapshot: downloads[id])
        fileActivities[id] = activity
        return activity
    }

    /// 同一轮事件（引擎每次发出全部进行中文件的进度）只重新计算一次。
    private func markChanged(_ id: Job.ID) {
        guard jobActivities[id] != nil else { return }
        changedJobs.insert(id)
        guard !isActivityUpdateScheduled else { return }
        isActivityUpdateScheduled = true
        Task { updateActivities() }
    }

    private func updateActivities() {
        isActivityUpdateScheduled = false
        let changed = changedJobs
        changedJobs = []
        for id in changed {
            guard let activity = jobActivities[id] else { continue }
            refresh(activity, for: id)
        }
    }

    private func refresh(_ activity: JobActivity, for id: Job.ID) {
        guard let job = job(id), let tally = tallies[id] else { return }
        // 引擎只给下载中的文件报告非 0 的速度，所以只加这些文件。按文件顺序加，结果和 `progress(of:)` 完全相同。
        let speed = tally.runningFiles.sorted().reduce(0.0) { $0 + (downloads[job.files[$1].id]?.bytesPerSecond ?? 0) }
        let progress = JobProgress(receivedBytes: tally.completedBytes + tally.receivedBytes, totalBytes: tally.totalBytes,
                                   bytesPerSecond: speed)
        let isRunning = !tally.runningFiles.isEmpty
        if let handler = tallyMismatchHandler {
            let scanned = (self.progress(of: job), job.files.contains { !$0.isCompleted && downloads[$0.id]?.state == .running })
            if progress != scanned.0 || isRunning != scanned.1 {
                handler("job \(job.id): activity \(progress) \(isRunning), scanning gives \(scanned.0) \(scanned.1)")
            }
        }
        if activity.progress != progress { activity.progress = progress }
        if activity.isRunning != isRunning { activity.isRunning = isRunning }
        let completed = job.files.count - tally.pendingCount
        if activity.completedFileCount != completed { activity.completedFileCount = completed }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case let failure as DownloadFailure: failure.message
        case let error as LocalizedError: error.errorDescription ?? error.localizedDescription
        default: error.localizedDescription
        }
    }
}

/// 一个任务的文件下载计数。`evaluate` 和任务的汇总进度只读它，不遍历文件列表：
/// 每个事件都遍历时，几千个文件的任务会让主线程忙几十秒。
///
/// 每个文件的部分只由它是否完成和它在 `downloads` 中的状态决定，所以修改其中之一时，先减去原来的部分，再加上新的部分。
private struct JobTally: Equatable {
    var totalBytes: Int64 = 0
    /// 没完成（没有 `localURL`）的文件。
    var pendingCount = 0
    var completedBytes: Int64 = 0
    /// 下面几项只算没完成、并且在 `downloads` 中有状态的文件。
    var trackedCount = 0
    var queuedCount = 0
    var pausedCount = 0
    var failedCount = 0
    var receivedBytes: Int64 = 0
    /// 正在下载的文件的下标。速度不在这里累加：浮点数反复加减会留下误差，没有下载时仍显示很小的速度。
    var runningFiles: Set<Int> = []

    init(files: [JobFile], downloads: [String: DownloadSnapshot]) {
        for (index, file) in files.enumerated() {
            add(file, at: index, downloads[file.id])
        }
    }

    mutating func add(_ file: JobFile, at index: Int, _ snapshot: DownloadSnapshot?) {
        apply(file, at: index, snapshot, sign: 1)
    }

    mutating func remove(_ file: JobFile, at index: Int, _ snapshot: DownloadSnapshot?) {
        apply(file, at: index, snapshot, sign: -1)
    }

    private mutating func apply(_ file: JobFile, at index: Int, _ snapshot: DownloadSnapshot?, sign: Int) {
        totalBytes += Int64(sign) * file.size
        if file.isCompleted {
            completedBytes += Int64(sign) * file.size
            return
        }
        pendingCount += sign
        guard let snapshot else { return }
        trackedCount += sign
        receivedBytes += Int64(sign) * snapshot.receivedBytes
        switch snapshot.state {
        case .queued: queuedCount += sign
        case .running:
            if sign > 0 { runningFiles.insert(index) } else { runningFiles.remove(index) }
        case .paused: pausedCount += sign
        case .failed: failedCount += sign
        case .completed: break
        }
    }
}

/// `evaluate` 得出的任务下一步。
private enum Outcome: Equatable {
    case finish
    /// 让暂停的文件下载继续。
    case reconcile
    case fail(DownloadFailure)
    /// 结果还没确定，或任务已暂停。
    case wait
}

enum TransferCheckError: LocalizedError {
    case noFiles
    case incompleteTransfer(String)
    case unconfirmedManifest(String)
    case unconfirmedTransfer
    case missingJobDirectory
    case outsideJobDirectory(String)
    /// 网盘任务列出的文件不在勾选的条目中。
    case outsideCheckedEntry(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .unconfirmedTransfer:
            "转存结果尚未确认，已保留目录和回执。请核对原转存结果，不会自动重复提交或删除目录。"
        case .unconfirmedManifest(let reason):
            "旧任务没有转存文件清单，暂时无法确认完整结果，已保留目录和回执，不会重复提交或自动清理。请恢复原分享后重试核对。原因：\(reason)"
        case .incompleteTransfer(let path):
            "转存结果不完整或文件大小不一致（\(path)），已保留目录和回执。请稍后重试核对，不会重复转存或自动清理。"
        case .noFiles:
            "转存后网盘中没有找到文件，可能转存尚未完成，请重试。"
        case .missingJobDirectory:
            "任务记录中没有有效的任务子目录，无法转存。"
        case .outsideJobDirectory(let path):
            "转存后的文件“\(path)”不在任务子目录中，无法确定保存位置。"
        case .outsideCheckedEntry(let path):
            "列出的文件“\(path)”不在勾选的目录中，无法确定保存位置。"
        case .unsafePath(let path):
            "文件路径“\(path)”不能用作本地文件名，下载已停止。"
        }
    }
}

/// 遵循 `PermanentDownloadSourceError`：从 `AccountCheckedSource` 抛出时，引擎不再重试。
enum CoordinatorError: LocalizedError, PermanentDownloadSourceError {
    case notLoggedIn
    case otherAccount
    /// 网盘任务没有记录账号（只有手动修改的任务列表才会这样）。
    case unknownAccount

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "该任务的网盘尚未登录。"
        case .otherAccount: "这个任务是用另一个网盘账号创建的。请登录那个账号后再操作。"
        case .unknownAccount: "任务中没有记录网盘账号，不能确定文件在哪个账号的网盘中。请重新添加这个任务。"
        }
    }
}

extension DownloadFailure {
    public var message: String {
        switch self {
        case .network(let code): "网络错误：" + URLError(code).localizedDescription
        case .httpStatus(429, _), .httpStatus(509, _): "网盘请求受到限流，请降低并发数，稍后继续下载。"
        case .httpStatus(401, _), .httpStatus(403, _): "下载权限不足或链接已失效，请重试刷新链接；仍失败时重新登录对应网盘。"
        case .httpStatus(404, _): "文件或下载链接不存在，请重试；仍失败时到对应网盘确认文件是否可用。"
        case .httpStatus(let status, _): "服务器返回 HTTP \(status)，请稍后重试。"
        case .invalidResponse(let reason): "下载的数据不正确（\(reason)）。"
        case .resolveFailed(let reason): "没有取得下载链接：\(reason)"
        case .fileSystem(let reason): "写入文件失败：\(reason)"
        }
    }
}
