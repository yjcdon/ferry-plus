import AppKit
import BaiduKit
import DownloadKit
import FerryCore
import Network
import Observation
import QuarkKit
import UserNotifications

/// 界面读取的全部状态：账号、设置和任务列表。界面的操作都经过它。
@Observable
final class AppModel {
    let quark: QuarkAccountSession
    private(set) var account: Account?
    private(set) var client: BaiduClient?
    /// 后台校验发现 Cookie 已失效。正在进行的下载不停止。
    private(set) var isLoginExpired = false
    var settings: FerrySettings {
        didSet { settingsDidChange() }
    }
    private(set) var downloadDirectory: URL
    /// 用户选择的下载目录无法访问时的说明。
    private(set) var downloadDirectoryProblem: String?
    /// SOCKS5 代理的密码。存在 Keychain 中，不在 `settings` 中。
    private(set) var proxyPassword: String
    /// 代理密码没能存入 Keychain 时的说明。这次运行仍使用新密码。
    private(set) var proxyPasswordProblem: String?
    let coordinator: JobCoordinator
    private(set) var uploadCoordinator: UploadCoordinator?
    /// 上传列表仅是编排器事件的只读投影，执行状态由编排器保存。
    private(set) var uploadJobs: [UploadJob] = []
    var uploadProblem: String?
    let integrityStore = IntegrityStore()
    var integrityRecordsRevision = 0
    @ObservationIgnored private let transferBudget: TransferBudget
    @ObservationIgnored private var uploadUpdates: Task<Void, Never>?
    @ObservationIgnored private var uploadActivityUpdates: Task<Void, Never>?
    @ObservationIgnored private var uploadReadSession: URLSession?

    /// 主窗口的 sheet。同一时间只显示一个。
    enum Sheet: String, Identifiable {
        case addLink

        var id: String { rawValue }
    }

    var sheet: Sheet?
    /// 主窗口自己的确认／详情占用展示时，分享入口不能再打开另一层 sheet。
    var isWorkspaceDialogPresented = false
    var workspaceRequest: WorkspaceRequest?
    /// 菜单栏发起的百度退出确认由主窗口承载，避免菜单关闭后丢失对话框。
    var isConfirmingMenuLogOut = false
    var lastAddedJobID: UUID?
    private(set) var lastAddedUploadID: UUID?
    @ObservationIgnored var openQuarkLoginWindow: (() -> Void)?

    /// 移除任务时没能移到废纸篓的文件或目录。界面提示后清空。
    var untrashedItems: [URL] = []

    /// 登录窗口显示的登录方式。
    enum LoginMethod {
        case web
        case cookie
    }

    /// 打开登录窗口时设定，用户在窗口中可以切换。
    var loginMethod = LoginMethod.web
    /// 主窗口关闭后，用它重新打开（例如点击 Dock 图标）。
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored var openLoginWindow: (() -> Void)?

    @ObservationIgnored private let source: RoutedDownloadSource
    @ObservationIgnored private let engine: DownloadEngine
    @ObservationIgnored private let downloadActivity = DownloadActivity()
    @ObservationIgnored private var installedQuarkClient: QuarkClient?
    /// 当前登录的凭据。换代理时用它同步创建新客户端；后台校验用它判断期间是否换了账号，因为换代理也会换 `client`。
    @ObservationIgnored private var credential: Credential?
    /// 引擎和 `client` 的会话使用的代理。只在它变化时换会话。
    @ObservationIgnored private var activeProxy: ActiveProxy?
    /// 最近一次换引擎会话的 Task。下一次先等它完成，因为各个 Task 到达引擎的顺序不一定和创建顺序相同。
    @ObservationIgnored private var sessionReplacement: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var quarkStartupTask: Task<Void, Never>?
    @ObservationIgnored private var transferLifecycle: TransferLifecycle?
    @ObservationIgnored private var isSystemSleeping = false
    @ObservationIgnored private var downloadIsExecuting = false
    @ObservationIgnored private var uploadIsExecuting = false
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var notificationAuthorizationTask: Task<Bool, Never>?
    /// 最近一次读取剪贴板的结果。剪贴板没变时不再读取，所以每次复制最多触发一次系统的剪贴板隐私提示，
    /// 也最多自动打开一次添加链接。
    @ObservationIgnored private var pasteboardCheck: (changeCount: Int, link: DiskShareLink?)?
    /// 设置中的下载目录。应用在选择期间一直持有它的访问权限；任务另外持有各自目录的访问权限。
    @ObservationIgnored private var accessedDirectory: URL?

    private static let settingsKey = "settings"

    /// 沙盒中的“下载”目录是指向用户“下载”目录的符号链接。解析后显示和保存真实路径。
    static var defaultDownloadDirectory: URL { URL.downloadsDirectory.resolvingSymlinksInPath() }

    /// 正在使用系统的“下载”目录：没有选择过目录、选择的就是它，或之前选择的目录无法访问。
    var usesDefaultDownloadDirectory: Bool {
        downloadDirectory.standardizedFileURL.path == Self.defaultDownloadDirectory.standardizedFileURL.path
    }

    init() {
        var settings = AppPreferences.defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(FerrySettings.self, from: $0) } ?? FerrySettings()
        #if DEBUG
        if DemoData.isEnabled { settings = FerrySettings() }
        if Self.isDriveVerification { settings.detectsCopiedLinks = false }
        #endif
        let proxyPassword = ProxyPasswordStore.load()
        let proxy = ActiveProxy(settings.proxy, password: proxyPassword)
        let source = RoutedDownloadSource()
        var stateDirectory = FerryDirectories.downloadState
        var jobsFile = FerryDirectories.jobsFile
        #if DEBUG
        if DemoData.isEnabled {
            stateDirectory = DemoData.directory.appendingPathComponent("Downloads", isDirectory: true)
            jobsFile = DemoData.directory.appendingPathComponent("jobs.json")
        }
        if Self.isDriveVerification {
            let directory = URL(filePath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/verification-session-\(UUID().uuidString)", isDirectory: true)
            stateDirectory = directory.appendingPathComponent("Downloads", isDirectory: true)
            jobsFile = directory.appendingPathComponent("jobs.json")
        }
        #endif
        let checkedSource = AccountCheckedSource(source)
        // 固定的正数连接上限和零速率均满足预算构造契约。
        let transferBudget = try! TransferBudget(maximumConnections: FerrySettings.totalConnectionsLimit,
            uploadBytesPerSecond: settings.uploadBytesPerSecond, downloadBytesPerSecond: settings.downloadBytesPerSecond)
        let engine = DownloadEngine(stateDirectory: stateDirectory, source: checkedSource,
                                    configuration: settings.downloadConfiguration(),
                                    sessionConfiguration: Self.applying(proxy, to: DownloadEngine.defaultSessionConfiguration()),
                                    transferBudget: transferBudget)
        self.transferBudget = transferBudget
        self.settings = settings
        quark = QuarkAccountSession(configuration: Self.applying(proxy, to: QuarkClient.defaultConfiguration()))
        self.proxyPassword = proxyPassword
        activeProxy = proxy
        self.source = source
        self.engine = engine
        downloadDirectory = Self.defaultDownloadDirectory
        coordinator = JobCoordinator(engine: engine, store: JobStore(fileURL: jobsFile),
                                     settings: settings, downloadFolder: DownloadFolder(url: Self.defaultDownloadDirectory), integrityStore: integrityStore)
        coordinator.onIntegrityRecordsChanged = { [weak self] in self?.integrityRecordsRevision += 1 }
        checkedSource.connect(coordinator)
        coordinator.onJobCompleted = { [weak self] job in self?.notifyCompletion(of: job) }
        #if DEBUG
        if Self.isDriveVerification { coordinator.onJobCompleted = nil }
        #endif
        coordinator.onRunningChanged = { [weak self] active in
            self?.downloadIsExecuting = active
            self?.updateTransferActivity()
        }
        resolveDownloadDirectory()
        #if DEBUG
        if DemoData.isEnabled {
            if DemoData.isLoggedIn {
                account = DemoData.account
            }
            return
        }
        #endif
        if let login = CredentialStore.load() {
            apply(makeClient(credential: login.credential), credential: login.credential, account: login.account)
        }
    }

    #if DEBUG
    /// 接口验证使用独立任务空间，不能恢复或修改主应用的真实任务列表。
    private static var isDriveVerification: Bool {
        ProcessInfo.processInfo.arguments.contains("--verify-drive-interfaces") ||
            ProcessInfo.processInfo.arguments.contains("--verify-drive-resume") ||
            ProcessInfo.processInfo.arguments.contains("--verify-drive-natural-expiry")
    }

    /// 复用正式账号路由解析一次候选链接，只返回脱敏到期元数据，不建立任务或请求下载正文。
    func verificationLinkExpiry(_ entry: RemoteEntry, account: AccountKey) async throws -> RangeVerificationGate.ExpiryMetadata {
        let context = DownloadContext(account: account, reference: entry.reference, size: entry.size, md5: entry.md5)
        let request = DownloadRequest(id: UUID().uuidString,
            destination: FileManager.default.temporaryDirectory.appendingPathComponent("Ferry-expiry-inspection"),
            expectedSize: entry.size, context: try context.encoded())
        let link = try await source.resolve(request)
        return RangeVerificationGate.expiryMetadata(link.url)
    }

    /// 等待期间主应用可能退出或换号；探测前仅核对当前钥匙串账号身份，不发布凭据。
    func naturalExpiryAccountMatches(_ encoded: Data) throws -> Bool {
        let context = try JSONDecoder().decode(DownloadContext.self, from: encoded)
        switch context.account.provider {
        case .baidu:
            guard let saved = CredentialStore.load() else { return false }
            return context.account == AccountKey(provider: .baidu, accountID: String(saved.account.uk))
        case .quark:
            guard let saved = try QuarkCredentialStore.load() else { return false }
            return context.account == AccountKey(provider: .quark, accountID: saved.account.id)
        }
    }

    /// 自然过期验证独立保存分片，仅保留正式来源和网络配置；链接留在包装来源的进程内存中。
    func naturalExpiryContext(_ sample: RemoteEntry, account: AccountKey, directory: URL) throws -> NaturalExpiryContext {
        let context = DownloadContext(account: account, reference: sample.reference, size: sample.size, md5: sample.md5)
        let request = DownloadRequest(id: UUID().uuidString, destination: directory.appendingPathComponent("sample.bin"),
            expectedSize: sample.size, context: try context.encoded(), connections: 1, expectedMD5: sample.md5)
        return NaturalExpiryContext(directory: directory, request: request, source: NaturalExpirySource(base: source),
            network: Self.applying(activeProxy, to: DownloadEngine.defaultSessionConfiguration()))
    }

    /// 用同一来源路由和代理创建隔离的正式下载栈；验证护栏只改变传输边界，不替换账号或下载内容。
    func makeResumeVerificationStack(directory: URL, disk: any Netdisk, lowerOffset: Int64,
                                     totalSize: Int64) -> (JobCoordinator, RangeVerificationGate) {
        var settings = self.settings
        settings.maxConcurrentFiles = 1
        settings.connectionsPerFile = 1
        settings.quarkConnectionsPerFile = 1
        settings.cleanupAfterDownload = false
        settings.quarkCleanupAfterDownload = false
        let configuration = DownloadConfiguration(maxConcurrentFiles: 1, segmentsPerFile: 1,
            segmentSize: .fixed(RangeVerificationGate.window), maxRetries: 0,
            progressInterval: .milliseconds(100), checkpointInterval: .seconds(60))
        let network = Self.applying(activeProxy, to: DownloadEngine.defaultSessionConfiguration())
        let gate = RangeVerificationGate(lowerOffset: lowerOffset, totalSize: totalSize, configuration: network)
        let guardedNetwork = network.copy() as! URLSessionConfiguration
        guardedNetwork.protocolClasses = [RangeVerificationProtocol.self]
        let checkedSource = AccountCheckedSource(source)
        let engine = DownloadEngine(stateDirectory: directory.appendingPathComponent("Downloads", isDirectory: true),
                                    source: checkedSource, configuration: configuration, sessionConfiguration: guardedNetwork)
        let coordinator = JobCoordinator(engine: engine, store: JobStore(fileURL: directory.appendingPathComponent("jobs.json")),
            settings: settings, downloadFolder: DownloadFolder(url: directory.appendingPathComponent("Files", isDirectory: true)),
            baseConfiguration: configuration)
        coordinator.netdisks[disk.account.provider] = disk
        checkedSource.connect(coordinator)
        return (coordinator, gate)
    }
    #endif

    // MARK: - 生命周期

    /// 恢复任务后校验账号；退出一旦开始，恢复期间的晚返回不能再发起账号校验。
    func start() async {
        guard !hasStarted, !isShuttingDown else { return }
        hasStarted = true
        #if DEBUG
        if DemoData.isEnabled {
            let demo = DemoData.hasJobs ? DemoData.make() : (jobs: [], downloads: [])
            coordinator.showDemo(jobs: demo.jobs, downloads: demo.downloads)
            return
        }
        #endif
        quark.onSessionChange = { [weak self] client, summary in self?.installQuark(client, summary: summary) }
        quark.performSessionChange = { [weak self] operation in
            guard let self else { throw CancellationError() }
            try await self.performProviderChange(.quark, operation: operation)
        }
        transferLifecycle = TransferLifecycle { [weak self] sleeping in self?.systemSleepChanged(sleeping) }
        quark.publishRestoredSession()
        await coordinator.start()
        guard !isShuttingDown else { return }
        await startUploads()
        guard !isShuttingDown else { return }
        quarkStartupTask = Task { [weak self] in
            guard self?.isShuttingDown == false, let quark = self?.quark else { return }
            await quark.start()
        }
        // 启动时应用变为活跃的那次检测在任务列表加载前，被跳过，所以加载后再检测一次。
        if NSApp.isActive { await detectCopiedLink() }
        guard !isShuttingDown else { return }
        await revalidate()
    }

    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        isShuttingDown = true
        quarkStartupTask?.cancel()
        // 系统授权提示不一定响应取消；不等待它，回调返回后会再次检查取消状态。
        notificationAuthorizationTask?.cancel()
        uploadUpdates?.cancel()
        uploadActivityUpdates?.cancel()
        transferLifecycle?.close()
        transferLifecycle = nil
        let previous = sessionReplacement
        let task = Task {
            await previous?.value
            await uploadCoordinator?.shutdown()
            uploadReadSession?.invalidateAndCancel()
            uploadReadSession = nil
            await coordinator.shutdown()
            await transferBudget.shutdown()
            downloadActivity.close()
            releaseAccessedDirectory()
        }
        shutdownTask = task
        sessionReplacement = task
        await task.value
    }

    /// 所有运行时网络切换按同一顺序收尾；任务不等待此 lane 来提供客户端或完成通知。
    private func enqueueSessionReplacement(_ operation: @escaping @MainActor () async -> Void) {
        let previous = sessionReplacement
        sessionReplacement = Task {
            await previous?.value
            guard !isShuttingDown else { return }
            await operation()
        }
    }

    /// 仅阻断发生变更的网盘；全局睡眠／代理阻断仍由其各自的生命周期操作控制。
    private func enqueueProviderChange(_ provider: Provider,
                                      operation: @escaping @MainActor () async throws -> Void) -> Task<Void, Error> {
        let previous = sessionReplacement
        let change = Task {
            await previous?.value
            guard !isShuttingDown else { throw CancellationError() }
            try Task.checkCancellation()
            await uploadCoordinator?.suspendExecution(for: provider)
            do {
                try Task.checkCancellation()
                guard !isShuttingDown else { throw CancellationError() }
                try await operation()
                if !isShuttingDown, accountKey(for: provider) != nil {
                    await uploadCoordinator?.resumeExecution(for: provider)
                }
            } catch {
                if !isShuttingDown, accountKey(for: provider) != nil {
                    await uploadCoordinator?.resumeExecution(for: provider)
                }
                throw error
            }
        }
        // 错误交还发起者；串行 lane 只等待收尾，不吞掉界面的错误结果。
        sessionReplacement = Task { _ = try? await change.value }
        return change
    }

    private func performProviderChange(_ provider: Provider,
                                       operation: @escaping @MainActor () async throws -> Void) async throws {
        let change = enqueueProviderChange(provider, operation: operation)
        try await withTaskCancellationHandler {
            try await change.value
        } onCancel: { change.cancel() }
    }

    /// 睡眠只改变运行时阻断，唤醒按原用户暂停意图继续，两个方向共用同一收尾 lane。
    private func systemSleepChanged(_ sleeping: Bool) {
        guard !isShuttingDown else { return }
        isSystemSleeping = sleeping
        enqueueSessionReplacement { [self] in
            if sleeping {
                await uploadCoordinator?.suspendExecution()
                await engine.suspendExecution()
            } else {
                await engine.resumeExecution()
                await uploadCoordinator?.resumeExecution()
            }
        }
    }

    /// 下载与上传／回读中的实际 worker 共用一个防休眠活动，没有定时轮询。
    private func updateTransferActivity() {
        downloadActivity.setActive(!isShuttingDown && (downloadIsExecuting || uploadIsExecuting))
    }

    // MARK: - 账号

    func logIn(cookie: String) async throws {
        try await logIn(credential: Credential.parse(cookie))
    }

    /// 校验凭据，通过后存入 Keychain 并开始使用。调用方取消时不保存。
    func logIn(credential: Credential) async throws {
        let proxy = activeProxy
        let client = makeClient(credential: credential)
        let account = try await client.validate()
        // 用户在校验期间取消了登录。
        try Task.checkCancellation()
        try await performProviderChange(.baidu) { [self] in
            try CredentialStore.save(StoredLogin(credential: credential, account: account))
            // 校验和 lane 等待期间都可能改代理，只安装当前网络配置的客户端。
            let currentClient = proxy == activeProxy ? client : makeClient(credential: credential)
            apply(currentClient, credential: credential, account: account)
        }
    }

    /// 凭据删除成功后才退出百度会话；失败沿账号变更流程展示，保留当前登录。
    func logOut() {
        let change = enqueueProviderChange(.baidu) { [self] in
            try CredentialStore.delete()
            client?.revoke()
            client = nil
            credential = nil
            account = nil
            isLoginExpired = false
            source.setBaidu(nil, account: nil)
            coordinator.netdisks[.baidu] = nil
        }
        Task {
            do { try await change.value }
            catch is CancellationError {} // 应用退出已接管全部收尾。
            catch { uploadProblem = error.localizedDescription }
        }
    }

    private func apply(_ client: BaiduClient, credential: Credential, account: Account) {
        self.account = account
        replaceClient(client)
        self.credential = credential
        isLoginExpired = false
    }

    /// 只换客户端，不改变账号和登录状态。
    private func replaceClient(_ client: BaiduClient) {
        self.client?.revoke()
        self.client = client
        let key = account.map { AccountKey(provider: .baidu, accountID: String($0.uk)) }
        source.setBaidu(client, account: key)
        if let key { coordinator.netdisks[.baidu] = BaiduNetdisk(client: client, account: key) }
        coordinator.accountNames[.baidu] = account?.username
    }

    private func makeClient(credential: Credential) -> BaiduClient {
        BaiduClient(credential: credential, configuration: Self.applying(activeProxy, to: BaiduClient.defaultConfiguration()))
    }

    /// 网络错误不算失效，只有百度明确说登录失效才提示。
    private func revalidate() async {
        guard !isShuttingDown, let client, let credential else { return }
        do {
            let account = try await client.validate()
            // 校验期间退出登录或换了账号。
            guard !isShuttingDown, credential == self.credential else { return }
            self.account = account
                try? CredentialStore.save(StoredLogin(credential: credential, account: account))
        } catch BaiduError.loginExpired {
            if !isShuttingDown, credential == self.credential, client === self.client { markBaiduExpired() }
        } catch {}
    }

    // MARK: - 设置

    private func settingsDidChange() {
        if AppPreferences.defaults.object(forKey: "settings.before-v3") == nil,
           let original = AppPreferences.defaults.data(forKey: Self.settingsKey) {
            AppPreferences.defaults.set(original, forKey: "settings.before-v3")
        }
        if let data = try? JSONEncoder().encode(settings) {
            AppPreferences.defaults.set(data, forKey: Self.settingsKey)
        }
        let settings = settings
        Task {
            await coordinator.updateSettings(settings)
            do {
                try await transferBudget.update(maximumConnections: FerrySettings.totalConnectionsLimit,
                    uploadBytesPerSecond: settings.uploadBytesPerSecond, downloadBytesPerSecond: settings.downloadBytesPerSecond)
                try await uploadCoordinator?.updateMaximumConcurrentJobs(settings.maxConcurrentUploads)
                try await uploadCoordinator?.updateMaximumConcurrentParts(settings.uploadPartsPerFile)
            } catch { uploadProblem = error.localizedDescription }
        }
        updateProxy()
    }

    // MARK: - 代理

    /// 实际生效的代理。使用系统设置或设置不完整时为 nil，这时会话使用系统的代理设置。
    private struct ActiveProxy: Equatable {
        var settings: ProxySettings
        var password: String

        init?(_ settings: ProxySettings, password: String) {
            guard settings.mode == .socks5, settings.problem(password: password) == nil else { return nil }
            self.settings = settings
            self.password = password
        }
    }

    /// 设置页显示的代理设置不完整的原因。
    var proxyProblem: String? {
        settings.proxy.problem(password: proxyPassword)
    }

    /// 设置页一次提交代理设置和密码，所以两者都变化时只换一次会话。
    func setProxy(_ proxy: ProxySettings, password: String) {
        if password != proxyPassword {
            proxyPassword = password
            do {
                try ProxyPasswordStore.save(password)
                proxyPasswordProblem = nil
            } catch {
                proxyPasswordProblem = error.localizedDescription
            }
        }
        if proxy != settings.proxy {
            settings.proxy = proxy
        } else {
            updateProxy()
        }
    }

    /// 生效的代理变化时，引擎换会话，进行中的下载从断点继续；已登录时用同一个凭据换客户端。
    /// 已经发出的 API 请求在旧客户端上完成。
    private func updateProxy() {
        let proxy = ActiveProxy(settings.proxy, password: proxyPassword)
        guard proxy != activeProxy else { return }
        activeProxy = proxy
        let configuration = Self.applying(proxy, to: DownloadEngine.defaultSessionConfiguration())
        enqueueSessionReplacement { [self] in
            await uploadCoordinator?.suspendExecution()
            await engine.suspendExecution()
            guard !isShuttingDown else { return }
            // 快速切换只应用最后一次设置；后继 lane 负责解除本次已持有的全局阻断。
            guard proxy == activeProxy else { return }
            quark.updateConfiguration(Self.applying(proxy, to: QuarkClient.defaultConfiguration()))
            if let credential {
                replaceClient(BaiduClient(credential: credential,
                    configuration: Self.applying(proxy, to: BaiduClient.defaultConfiguration())))
            }
            await engine.replaceSession(configuration: configuration)
            let readSession = URLSession(configuration: configuration)
            do {
                let integrity = try IntegrityService(reader: RangeReader(session: readSession, budget: transferBudget))
                try await uploadCoordinator?.replaceIntegrityService(integrity)
                uploadReadSession?.invalidateAndCancel()
                uploadReadSession = readSession
                // updateConfiguration 暂时撤销再安装会话；按最终账号状态更新各家阻断。
                for provider in Provider.allCases where accountKey(for: provider) != nil {
                    await uploadCoordinator?.resumeExecution(for: provider)
                }
                if !isSystemSleeping, !isShuttingDown {
                    await engine.resumeExecution()
                    await uploadCoordinator?.resumeExecution()
                }
            } catch {
                readSession.invalidateAndCancel()
                uploadProblem = "更新上传校验网络失败：" + error.localizedDescription
            }
        }
    }

    private static func applying(_ proxy: ActiveProxy?, to configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        configuration.proxyConfigurations = proxy.map { $0.settings.proxyConfigurations(password: $0.password) } ?? []
        return configuration
    }

    /// 新任务默认的下载目录（设置中的下载目录）。任务记录它，以后每次启动用 bookmark 重新取得访问权限。
    var currentFolder: DownloadFolder {
        DownloadFolder(url: downloadDirectory, bookmark: accessedDirectory == nil ? nil : settings.downloadDirectoryBookmark)
    }

    private func resolveDownloadDirectory() {
        defer { coordinator.downloadFolder = currentFolder }
        guard let bookmark = settings.downloadDirectoryBookmark else {
            downloadDirectory = Self.defaultDownloadDirectory
            return
        }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
            guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
            if isStale, let renewed = try? url.bookmarkData(options: .withSecurityScope) {
                settings.downloadDirectoryBookmark = renewed
            }
            accessedDirectory = url
            downloadDirectory = url
            downloadDirectoryProblem = nil
        } catch {
            downloadDirectory = Self.defaultDownloadDirectory
            downloadDirectoryProblem = "文件将下载到“下载”目录，请重新选择下载位置。"
        }
    }

    /// `url` 来自用户在打开面板中的选择。
    func chooseDownloadDirectory(_ url: URL) {
        let isAccessing = url.startAccessingSecurityScopedResource()
        do {
            settings.downloadDirectoryBookmark = try url.bookmarkData(options: .withSecurityScope)
            releaseAccessedDirectory()
            if isAccessing { accessedDirectory = url }
            downloadDirectory = url
            downloadDirectoryProblem = nil
            coordinator.downloadFolder = DownloadFolder(url: url, bookmark: settings.downloadDirectoryBookmark)
        } catch {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
            downloadDirectoryProblem = "下载目录授权保存失败，请重新选择：\(error.localizedDescription)"
        }
    }

    /// 添加链接时为一个任务选择的下载目录。`url` 来自用户在打开面板中的选择。不修改设置。
    /// 任务开始时 `JobCoordinator` 用 bookmark 取得访问权限，所以这里只在创建 bookmark 期间访问。
    func makeDownloadFolder(for url: URL) throws -> DownloadFolder {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
        return DownloadFolder(url: url, bookmark: try url.bookmarkData(options: .withSecurityScope))
    }

    func useDefaultDownloadDirectory() {
        settings.downloadDirectoryBookmark = nil
        releaseAccessedDirectory()
        downloadDirectory = Self.defaultDownloadDirectory
        downloadDirectoryProblem = nil
        coordinator.downloadFolder = currentFolder
    }

    /// 之前选择的目录中未完成的任务持有自己的访问权限，所以这里可以交回。
    private func releaseAccessedDirectory() {
        accessedDirectory?.stopAccessingSecurityScopedResource()
        accessedDirectory = nil
    }

    // MARK: - 任务

    /// 来源由链接或文件窗口选择，入口不绑定百度登录。
    func presentAddLink() { present(.addLink) }

    /// 主窗口未显示时保留导航意图，已有请求或分享确认不被新的菜单操作覆盖。
    func requestWorkspace(_ action: WorkspaceRequest.Action) {
        guard sheet == nil, workspaceRequest == nil else { return }
        switch action {
        case .browse, .upload:
            guard canPresentShare else { return }
        case .locate:
            break // 详情先请求准确位置，再关闭自身，由主窗口消费。
        }
        workspaceRequest = .init(action: action)
    }

    /// 上传结果携带原账号和准确目录，不能使用当前另一账号的同名位置。
    func requestCloudLocation(account: AccountKey, directory: RemoteReference, focus: RemoteReference? = nil) {
        requestWorkspace(.locate(account, directory, focus))
    }

    func accountKey(for provider: Provider) -> AccountKey? { coordinator.netdisks[provider]?.account }

    /// 初始化一次上传编排，复用现有账号及三类传输共享预算；恢复失败保留原检查点并显示原因。
    private func startUploads() async {
        await sessionReplacement?.value
        guard !isShuttingDown else { return }
        guard uploadCoordinator == nil else { return }
        do {
            let session = URLSession(configuration: Self.applying(activeProxy, to: DownloadEngine.defaultSessionConfiguration()))
            uploadReadSession = session
            let integrity = try IntegrityService(reader: RangeReader(session: session, budget: transferBudget))
            let uploads = try UploadCoordinator(store: UploadStore(), integrityStore: integrityStore,
                budget: transferBudget, integrity: integrity, secrets: KeychainUploadSecretStorage(),
                maximumConcurrentJobs: settings.maxConcurrentUploads, maximumConcurrentParts: settings.uploadPartsPerFile,
                onBatchFinished: { [weak self] job in await self?.notifyUploadCompletion(of: job) },
                environment: { [weak self] key in
                    guard let self else { throw CancellationError() }
                    return try await self.uploadEnvironment(for: key)
                })
            uploadCoordinator = uploads
            uploadUpdates = Task { [weak self] in
                for await jobs in await uploads.updates() {
                    guard !Task.isCancelled else { break }
                    self?.uploadJobs = jobs
                }
            }
            uploadActivityUpdates = Task { [weak self] in
                for await active in await uploads.activityUpdates() {
                    guard !Task.isCancelled else { break }
                    self?.uploadIsExecuting = active
                    self?.updateTransferActivity()
                }
            }
            for provider in Provider.allCases where accountKey(for: provider) == nil {
                await uploads.suspendExecution(for: provider)
            }
            if isSystemSleeping { await uploads.suspendExecution() }
            try await uploads.restore()
        } catch {
            uploadProblem = error.localizedDescription
        }
    }

    /// 用户确认网盘、账号及目标后才持久化上传选择；拖入文件本身不产生云端写入。
    func addUpload(files: [URL], account: AccountKey, destination: RemoteReference,
                   conflictPolicy: UploadConflictPolicy) async throws {
        guard accountKey(for: account.provider) == account, let uploadCoordinator else {
            throw UploadDestinationError.otherAccount
        }
        let selections = try files.map { try UploadSelection(url: $0, bookmark: UploadSource.bookmark(for: $0)) }
        let name = coordinator.accountNames[account.provider] ?? account.provider.title
        requestNotificationAuthorization()
        let id = try await uploadCoordinator.add(account: account, accountName: name, destination: destination,
                                                selections: selections, conflictPolicy: conflictPolicy)
        uploadJobs = await uploadCoordinator.snapshots()
        lastAddedUploadID = id
    }

    /// 上传任务绑定创建时的账号和客户端；换号或换会话后不能把旧任务发给新账号。
    func uploadEnvironment(for key: AccountKey) throws -> UploadEnvironment {
        guard accountKey(for: key.provider) == key else { throw UploadDestinationError.otherAccount }
        switch key.provider {
        case .baidu:
            guard let client else { throw UploadDestinationError.otherAccount }
            return try UploadEnvironment.baidu(client: client, account: key) { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.checkUploadSession(key, baidu: client)
            }
        case .quark:
            guard let client = installedQuarkClient else { throw UploadDestinationError.otherAccount }
            return try UploadEnvironment.quark(client: client, account: key, secrets: KeychainUploadSecretStorage()) { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.checkUploadSession(key, quark: client)
            }
        }
    }

    /// 每次环境请求结束后仍核对同一实例，拒绝期间发生的退出、换号或代理会话替换。
    private func checkUploadSession(_ key: AccountKey, baidu: BaiduClient? = nil, quark: QuarkClient? = nil) throws {
        guard accountKey(for: key.provider) == key,
              baidu == nil || client === baidu,
              quark == nil || installedQuarkClient === quark else { throw UploadDestinationError.otherAccount }
    }

    /// 上传确认前查询当前账号可用空间；请求前后固定同一客户端，失败交由预检展示具体原因。
    func uploadAvailableBytes(for account: AccountKey) async throws -> Int64? {
        try checkUploadSession(account)
        switch account.provider {
        case .baidu:
            guard let client else { throw UploadDestinationError.otherAccount }
            try checkUploadSession(account, baidu: client)
            let capacity = try await client.capacity()
            try checkUploadSession(account, baidu: client)
            return max(0, capacity.total - capacity.used)
        case .quark:
            guard let client = installedQuarkClient else { throw UploadDestinationError.otherAccount }
            try checkUploadSession(account, quark: client)
            let capacity = try await client.capacity()
            try checkUploadSession(account, quark: client)
            return max(0, capacity.total - capacity.used)
        }
    }

    func netdisk(for provider: Provider) throws -> any Netdisk {
        guard let disk = coordinator.netdisks[provider] else {
            throw AppAccountError(message: "请登录\(provider.title)。")
        }
        return disk
    }

    func presentLogin(for provider: Provider) {
        if provider == .baidu { presentLogin() } else { openQuarkLoginWindow?() }
    }

    private func installQuark(_ client: QuarkClient?, summary: AccountSummary?) {
        if let client, installedQuarkClient === client, coordinator.netdisks[.quark]?.account == summary?.key { return }
        installedQuarkClient = client
        source.setQuark(client, account: summary?.key)
        if let client, let summary {
            coordinator.netdisks[.quark] = QuarkNetdisk(client: client, account: summary.key)
            coordinator.accountNames[.quark] = summary.name
        } else { coordinator.netdisks[.quark] = nil }
    }

    /// 分享入口与主窗口的确认、详情共用展示占用规则，避免剪贴板自动打开嵌套 sheet。
    private var canPresentShare: Bool {
        sheet == nil && !isWorkspaceDialogPresented && !isConfirmingMenuLogOut && untrashedItems.isEmpty
    }

    /// 已有确认或详情时不覆盖当前操作；手动与剪贴板分享使用同一入口条件。
    private func present(_ sheet: Sheet) {
        guard canPresentShare else { return }
        self.sheet = sheet
    }

    /// 应用变为活跃时调用。剪贴板中有新复制的分享链接时，打开添加链接，由 sheet 填入。
    /// 已有 sheet、剪贴板已经读过（包括手动打开添加链接时），或链接已经是一个任务的来源时不打开。
    func detectCopiedLink() async {
        let changeCount = NSPasteboard.general.changeCount
        guard !isShuttingDown, settings.detectsCopiedLinks, coordinator.isStarted, canPresentShare,
              pasteboardCheck?.changeCount != changeCount else { return }
        guard let link = await shareLinkOnPasteboard(), !Task.isCancelled, !isShuttingDown,
              settings.detectsCopiedLinks, canPresentShare,
              NSPasteboard.general.changeCount == changeCount,
              !coordinator.jobs.contains(where: { $0.link?.surl == link.surl }) else { return }
        openMainWindow?()
        present(.addLink)
    }

    /// 检测期间剪贴板变化或任务取消时不读取、缓存或打开过时结果，留待下次检测。
    func shareLinkOnPasteboard() async -> DiskShareLink? {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard !Task.isCancelled else { return nil }
        if let pasteboardCheck, pasteboardCheck.changeCount == changeCount {
            return pasteboardCheck.link
        }
        let mayContainURL = await pasteboardMayContainWebURL()
        guard !Task.isCancelled, pasteboard.changeCount == changeCount else { return nil }
        var link: DiskShareLink?
        if mayContainURL, let text = pasteboard.string(forType: .string) {
            link = DiskShareLink.parse(text)
        }
        guard pasteboard.changeCount == changeCount else { return nil }
        pasteboardCheck = (changeCount, link)
        return link
    }

    /// macOS 15.4 起，读取剪贴板内容会弹出隐私提示，所以先只检测有没有网址（不会弹出提示）。用户选择“始终拒绝”时不读取。
    /// 更早的系统读取剪贴板不弹提示，直接读取。
    private func pasteboardMayContainWebURL() async -> Bool {
        guard #available(macOS 15.4, *) else { return true }
        let pasteboard = NSPasteboard.general
        guard pasteboard.accessBehavior != .alwaysDeny,
              let patterns = try? await pasteboard.detectedPatterns(for: [\.probableWebURL]) else { return false }
        return patterns.contains(\.probableWebURL)
    }

    /// 先显示网页登录。
    func presentLogin() {
        loginMethod = .web
        openLoginWindow?()
    }

    /// 百度明确返回登录失效时，显示失效横幅。其他错误不影响登录状态。
    func noteError(_ error: any Error, from disk: any Netdisk) {
        guard coordinator.netdisks[disk.account.provider] === disk else { return }
        if let error = error as? BaiduError, error == .loginExpired, client != nil {
            markBaiduExpired()
        }
        if let error = error as? QuarkError, error == .loginExpired, let installedQuarkClient {
            Task { await quark.noteExpired(client: installedQuarkClient) }
        }
    }

    private func markBaiduExpired() {
        let expected = client
        let change = enqueueProviderChange(.baidu) { [self] in
            guard client === expected else { return }
            isLoginExpired = true
            client?.revoke()
            source.setBaidu(nil, account: nil)
            coordinator.netdisks[.baidu] = nil
        }
        Task {
            do { try await change.value }
            catch is CancellationError {}
            catch { uploadProblem = error.localizedDescription }
        }
    }

    /// 没有未完成的任务时直接退出登录，返回 false；否则返回 true，由界面先确认。
    func requestLogOut() -> Bool {
        guard hasUnfinishedJobs else {
            logOut()
            return false
        }
        return true
    }

    var hasUnfinishedJobs: Bool {
        coordinator.jobs.contains { $0.provider == .baidu && $0.isUnfinished }
    }

    /// `downloadFolder` 为 nil 时，任务使用设置中的下载目录。
    func addJob(session: DiskShareSession, entries: [RemoteEntry], downloadFolder: DownloadFolder? = nil) {
        guard accountKey(for: session.account.provider) == session.account else { return }
        lastAddedJobID = coordinator.addJob(session: session, entries: entries, downloadFolder: downloadFolder).id
        requestNotificationAuthorization()
    }

    /// `accountUK` 是勾选的条目所在网盘的账号。`downloadFolder` 为 nil 时，任务使用设置中的下载目录。
    func addNetdiskJob(entries: [RemoteEntry], account: AccountKey, downloadFolder: DownloadFolder? = nil) {
        guard accountKey(for: account.provider) == account else { return }
        lastAddedJobID = coordinator.addNetdiskJob(entries: entries, account: account, downloadFolder: downloadFolder).id
        requestNotificationAuthorization()
    }

    /// 启动恢复完成前和移除期间，任务不接受操作。
    func canOperate(on job: Job) -> Bool {
        coordinator.isStarted && coordinator.restorationProblem == nil && !coordinator.removingJobs.contains(job.id)
    }

    func pause(_ job: Job) {
        Task { await coordinator.pause(job.id) }
    }

    func resume(_ job: Job) {
        Task { await coordinator.resume(job.id) }
    }

    /// 其中可以执行 `action` 的任务。
    func jobs(in jobs: [Job], allowing action: JobAction) -> [Job] {
        jobs.filter { $0.allows(action) && canOperate(on: $0) }
    }

    /// 调用方先用 `jobs(in:allowing:)` 筛选任务。
    func perform(_ action: JobAction, on jobs: [Job]) {
        switch action {
        case .pause: jobs.forEach(pause)
        case .resume: jobs.forEach(resume)
        case .retry: jobs.forEach(retry)
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting(jobs.flatMap(\.revealURLs))
        }
    }

    func retry(_ job: Job) {
        Task { await coordinator.retry(job.id) }
    }

    /// 有可以操作、且有已下载文件的任务。
    func canTrashFiles(of jobs: [Job]) -> Bool {
        jobs.contains { canOperate(on: $0) && $0.files.contains(where: \.isCompleted) }
    }

    /// 主窗口等待实际移除结果；归档失败保持任务并将错误交回显示。
    func remove(_ job: Job, trashingFiles: Bool = false, cleanupConfirmed: Bool? = nil,
                integrityDisposition: DownloadIntegrityDisposition = .preserve) async throws {
        let failed = try await coordinator.remove(job.id, trashingFiles: trashingFiles, cleanupConfirmed: cleanupConfirmed,
                                                  integrityDisposition: integrityDisposition)
        untrashedItems += failed
    }

    // MARK: - 通知

    /// 首次任务共用一次授权请求；小文件即使先完成，也等待本次授权结果再发送通知。
    private func requestNotificationAuthorization() {
        guard notificationAuthorizationTask == nil else { return }
        let center = UNUserNotificationCenter.current()
        notificationAuthorizationTask = Task {
            guard !Task.isCancelled else { return false }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                return granted && !Task.isCancelled
            } catch { return false }
        }
    }

    /// 授权拒绝或通知提交失败只影响通知，不改变下载结果；异步任务不持有 AppModel。
    private func notifyCompletion(of job: Job) {
        let content = UNMutableNotificationContent()
        content.title = "下载完成"
        content.body = job.provider.title + " · " + job.title
        let request = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
        sendCompletionNotification(request, checkingCancellationAfterSettings: true)
    }

    /// 终态已保存且 worker 移除后刷新校验记录视图并通知；不等待生命周期 lane 或系统授权。
    private func notifyUploadCompletion(of job: UploadJob) {
        integrityRecordsRevision += 1
        guard !isShuttingDown else { return }
        let content = UNMutableNotificationContent()
        switch job.phase {
        case .completed: content.title = "上传完成"
        case .skipped: content.title = "上传结束，文件已跳过"
        default: content.title = job.hasPartialFailure ? "上传结束，部分文件未成功" : "上传失败"
        }
        content.body = job.account.provider.title + " · " + job.title +
            " · 完成 \(job.completedCount)，失败 \(job.failedCount)，跳过 \(job.skippedCount)"
        let request = UNNotificationRequest(identifier: "upload-" + job.id.uuidString, content: content, trigger: nil)
        sendCompletionNotification(request, checkingCancellationAfterSettings: false)
    }

    /// 共用授权等待与系统权限重查；保留两种传输原有的取消检查时点，不持有 AppModel。
    private func sendCompletionNotification(_ request: UNNotificationRequest,
                                            checkingCancellationAfterSettings: Bool) {
        let authorization = notificationAuthorizationTask
        let center = UNUserNotificationCenter.current()
        Task {
            if let authorization { _ = await authorization.value }
            guard !Task.isCancelled, authorization?.isCancelled != true else { return }
            // 权限可在运行中改变；授权Task的旧结果不替代当前系统许可，也不额外弹授权。
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            if checkingCancellationAfterSettings {
                guard !Task.isCancelled, authorization?.isCancelled != true else { return }
            }
            try? await center.add(request)
        }
    }

    isolated deinit {
        quarkStartupTask?.cancel()
        uploadUpdates?.cancel()
        uploadActivityUpdates?.cancel()
        transferLifecycle?.close()
    }
}

private struct AppAccountError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
