import AppKit
import FerryCore
import SwiftUI

/// 上传确认页只选择本地源和当前账号下的目标目录；扫描、哈希和远端写入交给提交入口。
struct UploadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var provider: Provider
    @State private var files: [URL]
    @State private var trail: [Folder]
    @State private var directories: [RemoteEntry] = []
    @State private var loadedAccount: AccountKey?
    @State private var loadedSession: ObjectIdentifier?
    @State private var loadedDirectory: RemoteReference?
    @State private var isLoading = false
    @State private var recentAttempted: AccountKey?
    @State private var restoresRecent = true
    @State private var directoryNotice: String?
    @State private var showsNewFolder = false
    @State private var newFolderName = ""
    @State private var creation: Creation?
    @State private var generation = 0
    @State private var loadError: String?
    @State private var selectionError: String?
    @State private var submitError: String?
    @State private var policy: UploadConflictPolicy = .keepBoth
    @State private var submission: Submission?
    @State private var isSubmitting = false
    @State private var isDropTarget = false
    @State private var preflight: UploadPreflightResult?
    @State private var preflightError: String?
    @State private var isCheckingPreflight = false
    @State private var panelPresenter = UploadOpenPanelPresenter()
    private let onSubmit: @MainActor ([URL], AccountKey, RemoteReference, UploadConflictPolicy) async throws -> Void

    private struct Folder: Identifiable {
        let reference: RemoteReference
        let name: String
        /// 从外部直接打开的夸克目录没有祖先路径，不能假装它是根目录的直接子级。
        let hasUnknownAncestors: Bool
        var id: RemoteReference { reference }
    }
    private struct LoadRequest: Hashable {
        let provider: Provider
        let directory: RemoteReference
        let generation: Int
        let session: ObjectIdentifier?
    }
    private struct PreflightRequest: Hashable {
        let files: [URL]
        let account: AccountKey
        let directory: RemoteReference
        let session: ObjectIdentifier
        let policy: UploadConflictPolicy
        let generation: Int
    }
    private struct Creation: Identifiable {
        let id = UUID()
        let name: String
        let parent: RemoteReference
        let account: AccountKey
        let session: ObjectIdentifier
    }
    private struct Submission: Identifiable {
        let id = UUID()
        let files: [URL]
        let account: AccountKey
        let directory: RemoteReference
        let policy: UploadConflictPolicy
        let session: ObjectIdentifier
        let trail: [RemoteEntry]?
    }

    init(initialProvider: Provider? = nil, initialDirectory: RemoteReference? = nil, files: [URL] = [], initialTrail: [RemoteEntry]? = nil,
         onSubmit: @escaping @MainActor ([URL], AccountKey, RemoteReference, UploadConflictPolicy) async throws -> Void) {
        _provider = State(initialValue: initialProvider ?? .baidu)
        _restoresRecent = State(initialValue: initialDirectory == nil)
        _files = State(initialValue: Self.uniqueLocalURLs(files.filter(\.isFileURL)))
        _selectionError = State(initialValue: files.contains(where: { !$0.isFileURL }) ? "只能上传本地文件或文件夹。" : nil)
        if let provider = initialProvider, let initialTrail, !initialTrail.isEmpty,
           initialTrail.allSatisfy({ $0.isDirectory && $0.reference.provider == provider }),
           initialTrail.last?.reference == initialDirectory {
            _trail = State(initialValue: initialTrail.map { .init(reference: $0.reference, name: $0.name, hasUnknownAncestors: false) })
        } else if let provider = initialProvider, let initialDirectory,
                  initialDirectory.provider == provider, initialDirectory != Self.root(for: provider) {
            let name: String
            switch initialDirectory {
            case .baidu(let path, _): name = (path as NSString).lastPathComponent
            case .quark: name = "已选文件夹"
            }
            _trail = State(initialValue: [.init(reference: initialDirectory, name: name, hasUnknownAncestors: true)])
        } else { _trail = State(initialValue: []) }
        self.onSubmit = onSubmit
    }

    var body: some View {
        let request = loadRequest
        VStack(spacing: 0) {
            header.padding()
            Picker("网盘", selection: $provider) {
                ForEach(Provider.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.bottom)
            .disabled(isSubmitting || creation != nil)
            Divider()
            fileSelection.padding()
            Divider()
            directoryHeader.padding(.horizontal).padding(.vertical, 10)
            directoryContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer.padding()
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 560, idealHeight: 660)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: 3).padding(4).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !isSubmitting, !urls.isEmpty else { return false }
            Self.appendFiles(urls, files: $files, error: $selectionError)
            return urls.contains(where: \.isFileURL)
        } isTargeted: { isDropTarget = $0 }
        .task(id: request) { await load(request) }
        .task(id: preflightRequest) { await checkPreflight(preflightRequest) }
        .alert("新建文件夹", isPresented: $showsNewFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("取消", role: .cancel) { }
            Button("新建") { beginCreation() }
                .disabled(!Self.validFolderName(newFolderName))
        } message: { Text("在当前目标目录中新建文件夹。") }
        .task(id: creation?.id) {
            guard let creation else { return }
            await createDirectory(creation)
        }
        .task(id: submission?.id) {
            guard let submission else { return }
            await submit(submission)
        }
        .onChange(of: provider) { resetDirectory() }
        .onChange(of: sessionIdentity) { resetDirectory() }
        .onDisappear { panelPresenter.cancel() }
    }

    private var header: some View {
        HStack {
            Text("上传到网盘").font(.headline)
            Spacer()
        }
    }

    private var fileSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("待上传项目").font(.subheadline.bold())
                Spacer()
                Text("\(files.count) 项").foregroundStyle(.secondary)
            }
            if !files.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(files, id: \.self) { url in
                            HStack {
                                Image(systemName: url.hasDirectoryPath ? "folder" : "doc")
                                    .foregroundStyle(.secondary)
                                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    .help(url.path(percentEncoded: false))
                                Spacer()
                                Button {
                                    files.removeAll { $0 == url }
                                    submitError = nil
                                } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("移除此项目")
                                .disabled(isSubmitting)
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(files.count) * 25, 100))
            }
            Button(action: chooseFiles) {
                VStack(spacing: 4) {
                    Text(files.isEmpty ? "点击选择文件或文件夹，也可拖到这里" : "点击继续添加文件或文件夹")
                    Text("应用程序等包文件按文件夹上传").font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: files.isEmpty ? 65 : 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            .accessibilityLabel("选择文件或文件夹")
            if let selectionError { errorLabel(selectionError) }
        }
    }

    private var directoryHeader: some View {
        HStack(spacing: 8) {
            Button {
                if !trail.isEmpty { trail.removeLast() }
            } label: { Image(systemName: "chevron.left") }
            .help("返回上一层浏览位置")
            .disabled(trail.isEmpty || isSubmitting || creation != nil)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    Button("根目录") { trail = [] }
                    ForEach(Array(trail.enumerated()), id: \.element.id) { index, folder in
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        if folder.hasUnknownAncestors { Text("…").foregroundStyle(.secondary) }
                        Button(folder.name) { trail = Array(trail.prefix(index + 1)) }
                    }
                }
                .buttonStyle(.plain)
                .lineLimit(1)
            }
            .disabled(isSubmitting || creation != nil)
            Spacer(minLength: 4)
            Button {
                newFolderName = ""; showsNewFolder = true
            } label: { Image(systemName: "folder.badge.plus") }
            .help("在当前目录新建文件夹")
            .disabled(!canUseDirectory)
            if creation != nil { ProgressView().controlSize(.small) }
            Button {
                generation += 1
            } label: { Image(systemName: "arrow.clockwise") }
            .help("刷新当前目录")
            .disabled(isSubmitting || isLoading || creation != nil)
        }
    }

    @ViewBuilder
    private var directoryContent: some View {
        if isLoading {
            ProgressView("正在读取文件夹…")
        } else if let loadError {
            ContentUnavailableView {
                Label("无法读取目标目录", systemImage: "exclamationmark.triangle")
            } description: { Text(loadError) } actions: {
                if model.accountKey(for: provider) == nil {
                    Button("登录\(provider.title)…") { model.presentLogin(for: provider) }
                } else {
                    Button("重试") { generation += 1 }
                }
            }
        } else if directories.isEmpty {
            ContentUnavailableView {
                Label("没有子文件夹", systemImage: "folder")
            } description: { Text("可以上传到当前目录。") }
        } else {
            List(directories) { directory in
                Button {
                    trail.append(.init(reference: directory.reference, name: directory.name, hasUnknownAncestors: false))
                } label: {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.tint)
                        Text(directory.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting || creation != nil)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("同名文件")
                Picker("同名文件", selection: $policy) {
                    Text("保留两份").tag(UploadConflictPolicy.keepBoth)
                    Text("跳过").tag(UploadConflictPolicy.skip)
                    Text("覆盖（暂不可用）").tag(UploadConflictPolicy.replace).disabled(true)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("覆盖须先验证网盘的并发保护和旧版本恢复能力，目前尚未开放。")
                .disabled(isSubmitting)
                Spacer()
            }
            Text("账号：\(accountName)　·　目标：\(destinationTitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            if let directoryNotice {
                Text(directoryNotice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            preflightContent
            if let submitError { errorLabel(submitError) }
            HStack {
                Text("上传完成后会校验云端内容。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isSubmitting { ProgressView().controlSize(.small) }
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button("上传", action: beginSubmission)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
    }

    private var sessionIdentity: ObjectIdentifier? {
        return model.coordinator.netdisks[provider].map { ObjectIdentifier($0) }
    }
    private var currentDirectory: RemoteReference {
        guard let reference = trail.last?.reference, reference.provider == provider else { return Self.root(for: provider) }
        return reference
    }
    private var loadRequest: LoadRequest {
        return .init(provider: provider, directory: currentDirectory, generation: generation, session: sessionIdentity)
    }
    private var accountName: String {
        guard model.accountKey(for: provider) != nil else { return "尚未登录" }
        return model.coordinator.accountNames[provider] ?? provider.title
    }
    private var destinationTitle: String {
        guard !trail.isEmpty else { return "根目录" }
        return "/" + trail.map { ($0.hasUnknownAncestors ? "…/" : "") + $0.name }.joined(separator: "/")
    }
    private var canSubmit: Bool {
        canUseDirectory && !files.isEmpty && policy != .replace && !isCheckingPreflight && preflight?.canUpload == true
    }
    private var preflightRequest: PreflightRequest? {
        let directory = currentDirectory
        guard !files.isEmpty, let account = loadedAccount, let session = loadedSession,
              account == model.accountKey(for: provider), loadedDirectory == directory,
              session == sessionIdentity, !isLoading else { return nil }
        return .init(files: files, account: account, directory: directory, session: session,
                     policy: policy, generation: generation)
    }

    @ViewBuilder private var preflightContent: some View {
        if isCheckingPreflight { ProgressView("正在检查文件及目标容量…").controlSize(.small) }
        else if let preflightError { errorLabel(preflightError) }
        else if let result = preflight {
            Text("\(result.summary.fileCount) 个文件 · \(result.summary.directoryCount) 个文件夹 · \(ByteCountFormatter.string(fromByteCount: result.summary.totalBytes, countStyle: .file))")
                .font(.caption).foregroundStyle(.secondary)
            Text(result.availableBytes.map { "剩余容量：" + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "剩余容量未知（\(result.capacityReason ?? "服务端未提供可靠容量")）")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            DisclosureGroup("上传前检查") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("单文件大小上限未知，以服务端结果为准。")
                        Text("同名项目 \(result.conflictCount) · 类型冲突 \(result.typeConflictCount) · 合并文件夹 \(result.mergingDirectoryCount)")
                        Text("这里只预览当前目录的根项目；子目录同名项在执行时逐项检查。预览不会锁定容量或目标。")
                        if result.requiredLowerBound != result.requiredUpperBound {
                            Text("跳过策略下所需空间尚不确定，最多需 \(ByteCountFormatter.string(fromByteCount: result.requiredUpperBound, countStyle: .file))。")
                        }
                        if result.summary.issueCount > 0 {
                            Text("发现 \(result.summary.issueCount) 个源问题；请处理后重新添加或刷新。")
                            ForEach(Array(result.summary.issues.enumerated()), id: \.offset) { _, message in
                                Text(message).textSelection(.enabled)
                            }
                            if result.summary.issueCount > result.summary.issues.count { Text("仅显示前 20 个问题。") }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxHeight: 120)
            }
            if result.insufficientSpace { errorLabel("目标剩余容量不足，请清理空间或减少本次上传内容。") }
            if result.summary.issueCount > 0 { errorLabel("所选源文件存在无法上传的项目，请展开检查。") }
        }
    }

    /// 只做可取消的元数据和只读容量／目录预览，变更选择或账号后丢弃旧结果。
    private func checkPreflight(_ request: PreflightRequest?) async {
        preflight = nil; preflightError = nil; isCheckingPreflight = request != nil
        guard let request else { return }
        do {
            let summary = try await UploadPreflight.inspect(request.files)
            try Task.checkCancellation()
            guard request == preflightRequest else { return }
            var available: Int64?, capacityReason: String?
            do { available = try await model.uploadAvailableBytes(for: request.account) }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                capacityReason = error.localizedDescription
            }
            let disk = try model.netdisk(for: request.account.provider)
            guard disk.account == request.account, ObjectIdentifier(disk) == request.session else { throw UploadDestinationError.otherAccount }
            let entries = try await disk.listDirectory(request.directory)
            try Task.checkCancellation()
            guard request == preflightRequest else { return }
            preflight = UploadPreflight.evaluate(summary, entries: entries, policy: request.policy,
                                                  availableBytes: available, capacityReason: capacityReason)
            isCheckingPreflight = false
        } catch {
            guard !Task.isCancelled, request == preflightRequest else { return }
            preflightError = error.localizedDescription; isCheckingPreflight = false
        }
    }
    private var canUseDirectory: Bool {
        let directory = currentDirectory
        return !isSubmitting && creation == nil && !isLoading && loadError == nil &&
        loadedAccount == model.accountKey(for: provider) && loadedAccount != nil &&
        loadedSession == sessionIdentity && loadedSession != nil && loadedDirectory == directory
    }

    /// Tab、换号或客户端会话更新后立即丢弃旧目录，已有本地文件选择仍可继续使用。
    private func resetDirectory() {
        trail = []; directories = []; loadedAccount = nil; loadedSession = nil; loadedDirectory = nil
        loadError = nil; submitError = nil; directoryNotice = nil; recentAttempted = nil; restoresRecent = true; generation += 1
    }

    /// .task 取消与请求身份双重核对，拒绝换号、切 Tab 和目录切换后的迟到响应。
    private func load(_ request: LoadRequest) async {
        guard request == loadRequest else { return }
        isLoading = true; loadError = nil; directories = []; loadedAccount = nil; loadedSession = nil; loadedDirectory = nil
        do {
            let disk = try model.netdisk(for: request.provider)
            let key = disk.account
            guard ObjectIdentifier(disk) == request.session else { throw CancellationError() }
            if recentAttempted != key {
                if restoresRecent, trail.isEmpty, let remembered = model.recentUploadDirectory(for: key), !remembered.isEmpty {
                    var parent = Self.root(for: request.provider)
                    var confirmed: [RemoteEntry] = []
                    for folder in remembered {
                        let entries = try await disk.listDirectory(parent)
                        try Task.checkCancellation()
                        guard request == loadRequest, model.accountKey(for: request.provider) == key,
                              sessionIdentity == ObjectIdentifier(disk) else { return }
                        guard let actual = entries.first(where: { $0.reference == folder.reference && $0.isDirectory }) else { break }
                        confirmed.append(actual); parent = actual.reference
                    }
                    if confirmed.count == remembered.count {
                        recentAttempted = key
                        trail = confirmed.map { .init(reference: $0.reference, name: $0.name, hasUnknownAncestors: false) }
                        return
                    }
                    model.forgetUploadDirectory(for: key)
                    directoryNotice = "最近上传目录已失效，已返回根目录，请重新确认目标。"
                }
                recentAttempted = key
            }
            let entries = try await disk.listDirectory(request.directory)
            try Task.checkCancellation()
            guard request == loadRequest, model.accountKey(for: request.provider) == key,
                  sessionIdentity == ObjectIdentifier(disk) else { return }
            directories = entries.filter(\.isDirectory).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            loadedAccount = key; loadedSession = ObjectIdentifier(disk); loadedDirectory = request.directory; isLoading = false
        } catch {
            guard !Task.isCancelled, request == loadRequest else { return }
            isLoading = false; loadError = error.localizedDescription
        }
    }

    /// 点击时冻结账号、会话、文件和目标；排队执行时不能重新读取可变 Tab 选择。
    private func beginSubmission() {
        let directory = currentDirectory
        guard canSubmit, let account = loadedAccount, let session = loadedSession else { return }
        submitError = nil; isSubmitting = true
        let remembered = trail.contains(where: \.hasUnknownAncestors) ? nil : trail.map {
            RemoteEntry(reference: $0.reference, name: $0.name, isDirectory: true, size: 0)
        }
        submission = .init(files: files, account: account, directory: directory, policy: policy, session: session, trail: remembered)
    }

    private func submit(_ request: Submission) async {
        defer { isSubmitting = false }
        do {
            try Task.checkCancellation()
            guard model.accountKey(for: request.account.provider) == request.account,
                  sessionIdentity == request.session else { throw UploadDestinationError.otherAccount }
            try await onSubmit(request.files, request.account, request.directory, request.policy)
            try Task.checkCancellation()
            if let trail = request.trail { model.rememberUploadDirectory(trail, for: request.account) }
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            submitError = error.localizedDescription
        }
    }

    /// 固定父目录和会话后只发一次创建请求；不确定回执必须由用户刷新核对。
    private func beginCreation() {
        let directory = currentDirectory
        guard canUseDirectory, Self.validFolderName(newFolderName),
              let account = loadedAccount, let session = loadedSession else { return }
        submitError = nil
        creation = .init(name: newFolderName, parent: directory, account: account, session: session)
    }

    private func createDirectory(_ request: Creation) async {
        defer { creation = nil }
        do {
            try Task.checkCancellation()
            guard currentDirectory == request.parent, model.accountKey(for: request.account.provider) == request.account,
                  sessionIdentity == request.session else { return }
            let entry = try await model.createUploadDirectory(name: request.name, parent: request.parent, account: request.account)
            try Task.checkCancellation()
            guard currentDirectory == request.parent, model.accountKey(for: request.account.provider) == request.account,
                  sessionIdentity == request.session else { return }
            trail.append(.init(reference: entry.reference, name: entry.name, hasUnknownAncestors: false))
            directoryNotice = nil
        } catch {
            guard !Task.isCancelled, currentDirectory == request.parent,
                  model.accountKey(for: request.account.provider) == request.account, sessionIdentity == request.session else { return }
            submitError = "新建结果未确认：\(error.localizedDescription)。文件夹可能已创建，请刷新核对后再操作。"
        }
    }

    private static func validFolderName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    /// 面板只增加本地项目，不枚举目录、不读文件内容，也不调用网盘写入。
    private func chooseFiles() {
        let files = $files, error = $selectionError
        panelPresenter.present { urls in Self.appendFiles(urls, files: files, error: error) }
    }

    private static func appendFiles(_ urls: [URL], files: Binding<[URL]>, error: Binding<String?>) {
        if urls.contains(where: { !$0.isFileURL }) { error.wrappedValue = "只能上传本地文件或文件夹。" }
        else { error.wrappedValue = nil }
        files.wrappedValue = uniqueLocalURLs(files.wrappedValue + urls.filter(\.isFileURL))
    }
    private static func uniqueLocalURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    }
    private static func root(for provider: Provider) -> RemoteReference {
        provider == .baidu ? .baidu(path: "/", fsID: 0) : .quark(fid: "0")
    }
    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
    }
}

/// 面板回调弱持有 presenter，关闭页面时取消；选择回调仅捕获文件 Binding，不持有 View。
@MainActor
private final class UploadOpenPanelPresenter {
    private var panel: NSOpenPanel?

    func present(onChoose: @escaping @MainActor ([URL]) -> Void) {
        guard panel == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true; panel.canCreateDirectories = false
        panel.prompt = "添加"
        self.panel = panel
        panel.begin { [weak self, weak panel] response in
            let urls = response == .OK ? panel?.urls : nil
            self?.panel = nil
            if let urls { onChoose(urls) }
        }
    }
    func cancel() {
        panel?.cancel(nil)
        panel = nil
    }
}
