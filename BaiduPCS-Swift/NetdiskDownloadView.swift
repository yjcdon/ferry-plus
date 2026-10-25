import BaiduKit
import FerryCore
import SwiftUI
import UniformTypeIdentifiers

/// 网盘下载和用户明确选择的校验依据在同一次确认中绑定账号、会话及准确远端身份。
struct NetdiskDownloadView: View {
    let initialAccount: AccountKey?
    let initialDirectory: RemoteReference?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var uploadTarget: UploadTarget?
    @State private var uploadSubmitted = false
    private struct UploadTarget: Identifiable {
        let id = UUID()
        let provider: Provider
        let account: AccountKey
        let session: ObjectIdentifier
        let trail: [RemoteEntry]
        let directory: RemoteReference
        let files: [URL]
    }
    @State private var tree: FileTree<RemoteEntry>?
    @State private var treeAccount: AccountKey?
    @State private var treeSession: ObjectIdentifier?
    @State private var provider: Provider = .baidu
    @State private var generation = 0
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var selectedFolder: DownloadFolder?
    @State private var folderError: String?
    @State private var showsIntegrity = false
    @State private var mode: IntegrityMode = .none
    @State private var algorithm: IntegrityAlgorithm = .sha256
    @State private var digest = ""
    @State private var candidates: [IntegrityRecord] = []
    @State private var candidateID: UUID?
    @State private var candidateGeneration = 0
    @State private var candidateError: String?
    @State private var isLoadingCandidates = false
    @State private var manifest: IntegrityManifest?
    @State private var manifestName: String?
    @State private var isImportPresented = false
    @State private var importRequest: ImportRequest?
    @State private var isImporting = false
    @State private var submission: Submission?
    @State private var integrityError: String?
    @State private var pendingDeletion: Deletion?
    @State private var deletion: Deletion?
    @State private var deletionResult: String?

    private struct Deletion: Identifiable {
        let id = UUID()
        let account: AccountKey
        let session: ObjectIdentifier
        let entries: [(entry: RemoteEntry, parent: RemoteReference)]
        let accountName: String
    }
    private var isBusy: Bool { isSubmitting || deletion != nil }
    private var browserRoot: RemoteReference { initialDirectory ?? provider.rootReference }

    init(initialAccount: AccountKey? = nil, initialDirectory: RemoteReference? = nil) {
        self.initialAccount = initialAccount
        self.initialDirectory = initialDirectory
        _provider = State(initialValue: initialAccount?.provider ?? .baidu)
    }

    private enum IntegrityMode: String, Identifiable {
        case none, manual, history, manifest
        var id: Self { self }
        var title: String {
            switch self { case .none: "不指定"; case .manual: "输入摘要"; case .history: "历史校验记录"; case .manifest: "JSON 清单" }
        }
    }
    private struct CandidateRequest: Hashable {
        let account: AccountKey
        let reference: RemoteReference
        let size: Int64
        let session: ObjectIdentifier
        let generation: Int
        let reload: Int
        let integrityRevision: Int
    }
    private struct ImportRequest: Identifiable {
        let id = UUID()
        let url: URL
    }
    private enum Choice {
        case none
        case manual(IntegrityAlgorithm, String)
        case history(IntegrityRecord)
        case manifest(IntegrityManifest)
    }
    private struct Submission: Identifiable {
        let id = UUID()
        let entries: [RemoteEntry]
        let account: AccountKey
        let session: ObjectIdentifier
        let generation: Int
        let folder: DownloadFolder?
        let choice: Choice
    }

    var body: some View {
        let candidate = candidateRequest
        VStack(spacing: 0) {
            header.padding()
            Picker("网盘", selection: $provider) {
                ForEach(Provider.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal).padding(.bottom).disabled(isBusy || initialAccount != nil)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(isBusy)
            Divider()
            footer.padding()
        }
        .frame(minWidth: 600, idealWidth: 680, minHeight: 460, idealHeight: 620)
        .sheet(item: $uploadTarget, onDismiss: {
            if uploadSubmitted { dismiss() }
            else { generation += 1 }
        }) { target in
            if model.accountKey(for: target.provider) == target.account,
               model.coordinator.netdisks[target.provider].map({ ObjectIdentifier($0) }) == target.session {
                UploadView(initialProvider: target.provider,
                           initialDirectory: target.directory,
                           files: target.files, initialTrail: target.trail) { files, account, destination, policy in
                    try await model.addUpload(files: files, account: account, destination: destination, conflictPolicy: policy)
                    uploadSubmitted = true
                }
                .environment(model)
            } else {
                ContentUnavailableView {
                    Label("账号已变化", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: { Text("请关闭后在当前账号中重新选择上传目录。") } actions: {
                    Button("关闭") { uploadTarget = nil }
                }
                .frame(width: 540, height: 320)
            }
        }
        .task(id: generation) { await load() }
        .task(id: deletion?.id) {
            guard let deletion else { return }
            await delete(deletion)
        }
        .alert("移到网盘回收站？", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { request in
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("移到回收站", role: .destructive) { pendingDeletion = nil; deletion = request }
        } message: { request in
            Text("\(request.account.provider.title) · \(request.accountName)\n\n\(request.entries.prefix(10).map { $0.entry.name }.joined(separator: "\n"))\n\n共 \(request.entries.count) 项。文件夹及其全部内容将移入该网盘回收站。")
        }
        .alert("网盘删除结果", isPresented: Binding(
            get: { deletionResult != nil }, set: { if !$0 { deletionResult = nil } }
        )) { Button("好") { deletionResult = nil } } message: { Text(deletionResult ?? "") }
        .task(id: candidate) { await loadCandidates(candidate) }
        .task(id: importRequest?.id) {
            guard let importRequest else { return }
            await importManifest(importRequest)
        }
        .task(id: submission?.id) {
            guard let submission else { return }
            await download(submission)
        }
        .onChange(of: sessionIdentity) { resetTree() }
        .onChange(of: provider) { resetTree() }
        .onChange(of: tree?.selection) { resetIntegrity() }
        .onChange(of: mode) {
            integrityError = nil
            if mode != .history { candidateID = nil }
            if mode != .manifest { importRequest = nil; isImporting = false }
        }
        .fileImporter(isPresented: $isImportPresented, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard mode == .manifest, !isSubmitting, let url = urls.first else { return }
                integrityError = nil; isImporting = true; importRequest = .init(url: url)
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { integrityError = error.localizedDescription }
            }
        }
    }

    private var sessionIdentity: ObjectIdentifier? {
        model.coordinator.netdisks[provider].map { ObjectIdentifier($0) }
    }
    private var selectedEntries: [RemoteEntry] { tree?.selectedEntries ?? [] }
    private var singleFile: RemoteEntry? {
        let entries = selectedEntries
        return entries.count == 1 && !entries[0].isDirectory ? entries[0] : nil
    }
    private var candidateRequest: CandidateRequest? {
        guard mode == .history, let file = singleFile, let account = treeAccount, let session = treeSession,
              model.accountKey(for: provider) == account, sessionIdentity == session else { return nil }
        return .init(account: account, reference: file.reference, size: file.size, session: session, generation: generation, reload: candidateGeneration,
                     integrityRevision: model.integrityRecordsRevision)
    }

    private var header: some View {
        HStack {
            Text(initialDirectory == nil ? "从我的网盘下载" : "上传结果所在目录").font(.headline)
            Spacer()
            if deletion != nil { ProgressView().controlSize(.small) }
            Button { prepareDeletion(selectedEntries) } label: { Label("删除选中项目", systemImage: "trash") }
                .labelStyle(.iconOnly).help("删除选中项目")
                .disabled(!canPresentUpload || selectedEntries.isEmpty)
            Button { presentUpload(trail: [], files: []) } label: { Label(initialDirectory == nil ? "上传到根目录" : "上传到当前目录", systemImage: "arrow.up.doc") }
                .labelStyle(.iconOnly)
                .help(initialDirectory == nil ? "上传到根目录" : "上传到当前目录").disabled(!canPresentUpload)
            Button { generation += 1; resetIntegrity() } label: { Label("重新加载", systemImage: "arrow.clockwise") }
                .labelStyle(.iconOnly).help("重新加载").disabled(isBusy)
        }
    }

    @ViewBuilder private var content: some View {
        if let tree {
            NetdiskBrowser(tree: tree, transferFolder: model.settings.transferFolder(for: provider), onUpload: { entry, files in
                guard let trail = directoryTrail(to: entry.reference, in: tree.root) else { return }
                presentUpload(trail: trail, files: files)
            }, onDelete: { prepareDeletion([$0]) }).id(ObjectIdentifier(tree))
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    guard !files.isEmpty, canPresentUpload else { return false }
                    presentUpload(trail: [], files: files)
                    return true
                }
        } else if let errorMessage {
            ContentUnavailableView {
                Label("无法读取网盘", systemImage: "exclamationmark.triangle")
            } description: { Text(errorMessage) } actions: {
                if model.accountKey(for: provider) == nil {
                    Button("登录\(provider.title)…") { model.presentLogin(for: provider) }
                } else { Button("重试") { generation += 1 } }
            }
        } else { ProgressView("正在读取网盘…") }
    }

    private var canPresentUpload: Bool {
        !isBusy && tree != nil && treeAccount == model.accountKey(for: provider) &&
        treeAccount != nil && treeSession == sessionIdentity && treeSession != nil
    }

    /// 浏览树中的目录引用和祖先来自同一已加载账号；勾选下载不会改变上传目标。
    private func presentUpload(trail: [RemoteEntry], files: [URL]) {
        guard canPresentUpload, uploadTarget == nil, let account = treeAccount, let session = treeSession else { return }
        uploadSubmitted = false
        uploadTarget = .init(provider: provider, account: account, session: session, trail: trail,
                             directory: trail.last?.reference ?? browserRoot, files: files)
    }

    private func directoryTrail(to reference: RemoteReference, in node: FileNode<RemoteEntry>, ancestors: [RemoteEntry] = []) -> [RemoteEntry]? {
        let trail = ancestors + (node.entry.map { [$0] } ?? [])
        if node.entry?.reference == reference { return trail }
        for child in node.children ?? [] {
            if let result = directoryTrail(to: reference, in: child, ancestors: trail) { return result }
        }
        return nil
    }

    /// 删除范围只来自当前树的精确条目；批量选择已有父级去重，不再递归枚举其内容。
    private func prepareDeletion(_ entries: [RemoteEntry]) {
        guard canPresentUpload, !entries.isEmpty, let tree, let account = treeAccount,
              let session = treeSession else { return }
        var targets: [(entry: RemoteEntry, parent: RemoteReference)] = []
        for entry in entries {
            guard let trail = directoryTrail(to: entry.reference, in: tree.root) else { return }
            targets.append((entry, trail.dropLast().last?.reference ?? browserRoot))
        }
        let name = provider == .baidu ? model.account?.username : model.quark.summary?.name
        pendingDeletion = .init(account: account, session: session, entries: targets,
                                accountName: name ?? account.accountID)
    }

    /// 每项只发送一次；保留部分成功，错误及换号不会转到新账号继续删除。
    private func delete(_ request: Deletion) async {
        var confirmed = 0
        var failures: [String] = []
        defer {
            deletion = nil
            resetIntegrity()
            generation += 1
        }
        for target in request.entries {
            do {
                try Task.checkCancellation()
                guard model.accountKey(for: request.account.provider) == request.account,
                      model.coordinator.netdisks[request.account.provider].map(ObjectIdentifier.init) == request.session else {
                    throw UploadRecordError.invalid("网盘账号或登录状态已变化，请刷新后重新操作。")
                }
                let disk = try model.netdisk(for: request.account.provider)
                try await disk.moveToTrash(entry: target.entry, parent: target.parent, account: request.account)
                confirmed += 1
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                failures.append("\(target.entry.name)：\(error.localizedDescription)")
                if model.accountKey(for: request.account.provider) != request.account || sessionIdentity != request.session { break }
            }
        }
        if !failures.isEmpty {
            deletionResult = "已确认移入回收站 \(confirmed) 项，未确认 \(request.entries.count - confirmed) 项。\n\n" + failures.joined(separator: "\n")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let tree { FileSelectionSummary(entries: tree.selectedEntries) }
            integrityControls
            if let folderError { errorLabel(folderError) }
            if let integrityError { errorLabel(integrityError) }
            HStack {
                DownloadFolderPicker(selection: $selectedFolder, error: $folderError).disabled(isBusy)
                Spacer()
                if isSubmitting { ProgressView().controlSize(.small) }
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(deletion != nil)
                Button("下载", action: beginDownload)
                    .keyboardShortcut(.defaultAction)
                    .disabled((tree?.selection.isEmpty ?? true) || isBusy || isImporting || folderError != nil)
            }
        }
    }

    private var integrityControls: some View {
        DisclosureGroup("内容校验", isExpanded: $showsIntegrity) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("校验依据", selection: $mode) {
                    Text(IntegrityMode.none.title).tag(IntegrityMode.none)
                    if singleFile != nil {
                        Text(IntegrityMode.manual.title).tag(IntegrityMode.manual)
                        Text(IntegrityMode.history.title).tag(IntegrityMode.history)
                    }
                    Text(IntegrityMode.manifest.title).tag(IntegrityMode.manifest)
                }.pickerStyle(.menu).fixedSize()
                switch mode {
                case .none:
                    Text("没有明确校验依据时，完成后显示“未验证源文件内容”。")
                        .font(.caption).foregroundStyle(.secondary)
                case .manual: manualInput
                case .history: historyInput
                case .manifest: manifestInput
                }
            }
            .padding(.top, 6)
        }
        .disabled(isBusy)
    }

    private var manualInput: some View {
        HStack {
            Picker("算法", selection: $algorithm) {
                Text("SHA-256").tag(IntegrityAlgorithm.sha256)
                Text("MD5").tag(IntegrityAlgorithm.md5)
            }.labelsHidden().frame(width: 110)
            TextField(algorithm == .sha256 ? "64 位十六进制 SHA-256" : "32 位十六进制 MD5", text: $digest)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
        }
    }

    @ViewBuilder private var historyInput: some View {
        Text("历史校验记录仅作为候选。请明确选择期望版本；不能据此认定云端内容仍未变化。")
            .font(.caption).foregroundStyle(.secondary)
        if isLoadingCandidates { ProgressView("正在读取候选…").controlSize(.small) }
        else if let candidateError {
            errorLabel(candidateError)
            Button("重新读取候选") { candidateGeneration += 1 }
        } else if candidates.isEmpty { Text("没有与账号、文件身份及大小匹配的已验证校验记录。").font(.caption).foregroundStyle(.secondary) }
        else {
            Picker("历史版本", selection: $candidateID) {
                Text("请选择期望版本").tag(UUID?.none)
                ForEach(candidates) { record in
                    if let expectation = record.expectation {
                        Text("\(record.verifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知时间") · \(expectation.algorithm == .sha256 ? "SHA-256" : "MD5") · \(expectation.origin.displayName) · \(expectation.digest.prefix(12))…")
                            .tag(Optional(record.id))
                    }
                }
            }
            if let selected = candidates.first(where: { $0.id == candidateID }), let expectation = selected.expectation {
                Text(expectation.digest).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
    }

    private var manifestInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("导入 JSON 清单…") { isImportPresented = true }.disabled(isImporting)
                if isImporting { ProgressView().controlSize(.small) }
                if let manifest {
                    Text("\(manifestName ?? "JSON 清单") · \(manifest.entries.count) 项").lineLimit(1).truncationMode(.middle)
                    Button("清除") { self.manifest = nil; manifestName = nil; mode = .none }
                }
            }
            Text("最多 4 MiB、10000 项。按完整相对路径及大小匹配；未列出的文件保持未验证。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func resetTree() {
        pendingDeletion = nil
        tree = nil; treeAccount = nil; treeSession = nil; errorMessage = nil
        resetIntegrity(); generation += 1
    }
    private func resetIntegrity() {
        mode = .none; digest = ""; candidateID = nil; candidates = []; candidateError = nil
        manifest = nil; manifestName = nil; importRequest = nil; isImportPresented = false; isImporting = false; integrityError = nil
    }

    /// 文件树绑定准确账号与客户端实例，重登录及代理替换后旧会话不能发布目录。
    private func load() async {
        tree = nil; treeAccount = nil; treeSession = nil
        let provider = self.provider
        let requestGeneration = generation
        do {
            let disk = try model.netdisk(for: provider)
            let key = disk.account
            if let initialAccount, key != initialAccount {
                throw UploadRecordError.invalid("网盘账号已变化，请登录原任务账号后重新定位。")
            }
            let session = ObjectIdentifier(disk)
            // 百度列目录使用路径，打开保存结果前还要核对 fsID，不能误认同路径的新目录。
            if case .baidu(let path, let fsID) = initialDirectory, fsID > 0 {
                let siblings = try await disk.listDirectory(.baidu(path: RemotePath.parent(of: path), fsID: 0))
                guard siblings.contains(where: { $0.reference == initialDirectory && $0.isDirectory }) else {
                    throw UploadRecordError.invalid("原上传目录已删除或发生变化，请重新浏览网盘。")
                }
            }
            try Task.checkCancellation()
            guard self.provider == provider, generation == requestGeneration,
                  model.accountKey(for: provider) == key, sessionIdentity == session else { return }
            errorMessage = nil
            let tree = FileTree<RemoteEntry>(initialSelection: .none) { [model, initialDirectory] directory in
                guard model.accountKey(for: provider) == key,
                      model.coordinator.netdisks[provider].map(ObjectIdentifier.init) == session else { throw CancellationError() }
                let entries = try await disk.listDirectory(directory?.reference ?? initialDirectory)
                try Task.checkCancellation()
                guard model.accountKey(for: provider) == key,
                      model.coordinator.netdisks[provider].map(ObjectIdentifier.init) == session else { throw CancellationError() }
                return entries
            } onError: { [model] in model.noteError($0, from: disk) }
            self.tree = tree; treeAccount = key; treeSession = session
            await tree.load(tree.root)
        } catch {
            guard !Task.isCancelled, self.provider == provider, generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadCandidates(_ request: CandidateRequest?) async {
        guard let request else { candidates = []; isLoadingCandidates = false; return }
        isLoadingCandidates = true; candidateError = nil
        do {
            try Task.checkCancellation()
            let result = try await model.integrityStore.candidates(account: request.account, reference: request.reference, size: request.size)
            try Task.checkCancellation()
            guard candidateRequest == request else { return }
            candidates = result; isLoadingCandidates = false
        } catch {
            guard !Task.isCancelled, candidateRequest == request else { return }
            candidateError = error.localizedDescription; isLoadingCandidates = false
        }
    }

    private func importManifest(_ request: ImportRequest) async {
        do {
            let manifest = try await IntegrityManifestDocument.read(at: request.url)
            try Task.checkCancellation()
            guard importRequest?.id == request.id, mode == .manifest else { return }
            self.manifest = manifest; manifestName = request.url.lastPathComponent; isImporting = false
        } catch {
            guard !Task.isCancelled, importRequest?.id == request.id else { return }
            manifest = nil; manifestName = nil; integrityError = error.localizedDescription; isImporting = false
        }
    }

    /// 确认前检查摘要格式及显式历史选择，错误输入不会触发目录枚举或创建任务。
    private func beginDownload() {
        guard !isBusy, !isImporting, !selectedEntries.isEmpty, let key = treeAccount, let session = treeSession,
              key == model.accountKey(for: provider), session == sessionIdentity else { return }
        do {
            let choice: Choice
            switch mode {
            case .none: choice = .none
            case .manual:
                guard let file = singleFile else { throw UploadRecordError.invalid("手输摘要只适用于一个文件") }
                let value = digest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let length = algorithm == .sha256 ? 64 : 32
                guard value.utf8.count == length, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw UploadRecordError.invalid("\(algorithm == .sha256 ? "SHA-256" : "MD5") 应为 \(length) 位十六进制摘要")
                }
                _ = try IntegrityExpectation(algorithm: algorithm, digest: value, origin: .userProvided, size: file.size, reference: file.reference)
                choice = .manual(algorithm, value)
            case .history:
                guard let candidateID, let record = candidates.first(where: { $0.id == candidateID }) else {
                    throw UploadRecordError.invalid("请明确选择要比较的历史校验基准")
                }
                choice = .history(record)
            case .manifest:
                guard let manifest else { throw UploadRecordError.invalid("请先导入校验清单") }
                choice = .manifest(manifest)
            }
            integrityError = nil; isSubmitting = true
            submission = .init(entries: selectedEntries, account: key, session: session, generation: generation,
                               folder: selectedFolder, choice: choice)
        } catch { integrityError = error.localizedDescription; showsIntegrity = true }
    }

    /// 清单只对本次冻结的远端文件作引用匹配；取消、换号或换会话后不创建任务。
    private func download(_ request: Submission) async {
        defer { isSubmitting = false }
        do {
            try Task.checkCancellation()
            let disk = try model.netdisk(for: request.account.provider)
            guard disk.account == request.account, ObjectIdentifier(disk) == request.session else { throw UploadDestinationError.otherAccount }
            let bindings: [DownloadIntegrityBinding]
            switch request.choice {
            case .none: bindings = []
            case .manual(let algorithm, let digest):
                guard request.entries.count == 1, let file = request.entries.first, !file.isDirectory else { throw UploadRecordError.invalid("摘要必须绑定单个文件") }
                let expectation = try IntegrityExpectation(algorithm: algorithm, digest: digest, origin: .userProvided,
                                                           size: file.size, reference: file.reference)
                bindings = [try DownloadIntegrityBinding(account: request.account, reference: file.reference, expectation: expectation)]
            case .history(let record):
                try record.validate()
                guard request.entries.count == 1, let file = request.entries.first, !file.isDirectory,
                      record.account == request.account, record.reference == file.reference, record.status == .verified,
                      let original = record.expectation, original.size == file.size else {
                    throw UploadRecordError.invalid("历史校验记录与当前选择不匹配")
                }
                let expectation = try IntegrityExpectation(algorithm: original.algorithm, digest: original.digest, origin: .userProvided,
                    size: file.size, reference: file.reference, remoteVersion: record.remoteVersion)
                bindings = [try DownloadIntegrityBinding(account: request.account, reference: file.reference, expectation: expectation)]
            case .manifest(let manifest):
                let files = try await disk.files(in: request.entries)
                guard files.count <= IntegrityManifest.maximumEntries else { throw UploadRecordError.invalid("单次清单校验最多选择 10000 个文件，请分批下载") }
                let selected = try files.map { try IntegrityManifestFile(relativePath: $0.relativePath, size: $0.entry.size, reference: $0.entry.reference) }
                bindings = try manifest.bindings(account: request.account, files: selected)
            }
            try Task.checkCancellation()
            guard generation == request.generation, treeAccount == request.account, treeSession == request.session,
                  model.accountKey(for: request.account.provider) == request.account,
                  model.coordinator.netdisks[request.account.provider].map(ObjectIdentifier.init) == request.session else {
                throw UploadDestinationError.otherAccount
            }
            try model.addNetdiskJob(entries: request.entries, account: request.account, downloadFolder: request.folder, integrityBindings: bindings)
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            integrityError = error.localizedDescription; showsIntegrity = true
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).textSelection(.enabled)
    }
}

/// 网盘的文件树：名称、修改日期和大小三列。
private struct NetdiskBrowser: View {
    let tree: FileTree<RemoteEntry>
    /// 设置中的转存目录。树中的这个目录显示“转存目录”标签。
    let transferFolder: String
    let onUpload: (RemoteEntry, [URL]) -> Void
    let onDelete: (RemoteEntry) -> Void
    @ScaledMetric private var dateWidth = 110
    @ScaledMetric private var sizeWidth = 72
    @State private var retryAttempt = 0

    var body: some View {
        let root = tree.root
        Group {
            if let children = root.children {
                if children.isEmpty {
                    ContentUnavailableView("网盘中没有文件", systemImage: "folder")
                } else {
                    List {
                        Section {
                            ForEach(children) { node in
                                FileTreeRow(node: node, tree: tree, isIncluded: false, badge: badge, columns: columns,
                                            onUpload: onUpload, onDelete: onDelete)
                            }
                        } header: {
                            columnHeaders
                        }
                    }
                }
            } else if let error = root.loadError {
                ContentUnavailableView {
                    Label("无法读取网盘", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { retryAttempt += 1 }
                }
            } else {
                ProgressView("正在读取网盘…")
            }
        }
        .task(id: retryAttempt) {
            guard retryAttempt > 0 else { return }
            await tree.load(root)
        }
    }

    private var columnHeaders: some View {
        HStack(spacing: 8) {
            Text("名称")
            Spacer()
            Text("修改日期")
                .frame(width: dateWidth, alignment: .leading)
            Text("大小")
                .frame(width: sizeWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func badge(_ entry: RemoteEntry) -> some View {
        if entry.isDirectory, RemotePath.normalized(entry.path) == RemotePath.normalized(transferFolder) {
            Text("转存目录")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: .rect(cornerRadius: 4))
                .fixedSize()
        }
    }

    private func columns(_ entry: RemoteEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.modifiedAt?.formatted(date: .abbreviated, time: .omitted) ?? "")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: dateWidth, alignment: .leading)
            // 目录也保留大小列宽度；EmptyView 会使这一列消失，导致日期右移。
            Text(entry.isDirectory ? "" : entry.size.byteCount)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: sizeWidth, alignment: .trailing)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
