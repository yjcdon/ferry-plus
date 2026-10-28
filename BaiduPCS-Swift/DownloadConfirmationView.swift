import FerryCore
import SwiftUI
import UniformTypeIdentifiers

/// 文件页明确选中的来源；确认期间不再从可变的浏览选择重新取得下载对象。
struct DownloadConfirmationTarget: Identifiable {
    let id = UUID()
    let account: AccountKey
    let session: ObjectIdentifier
    let entries: [RemoteEntry]
    var directory: RemoteReference? = nil
    var pathDescription: String? = nil
}

/// 固定来源后选择保存位置与校验依据；普通目录枚举继续由现有下载任务执行。
struct DownloadConfirmationView: View {
    let target: DownloadConfirmationTarget
    private let onSubmitted: @MainActor () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFolder: DownloadFolder?
    @State private var folderError: String?
    @State private var showsIntegrity = false
    @State private var integrity = IntegritySelection()
    @State private var submission: Submission?
    @State private var isSubmitting = false
    @State private var isCancelled = false
    @State private var contextInvalidated = false

    private enum IntegrityMode: String, Identifiable {
        case none, manual, history, manifest
        var id: Self { self }
        var title: String {
            switch self {
            case .none: "不指定"
            case .manual: "输入摘要"
            case .history: "历史校验记录"
            case .manifest: "JSON 清单"
            }
        }
    }

    /// 各模式保留自己的草稿；离开模式后不继续使用其历史选择或未完成的导入请求。
    private struct IntegritySelection {
        var mode: IntegrityMode = .none
        var manual = ManualDraft()
        var history = HistoryDraft()
        var manifest = ManifestDraft()
        var error: String?

        mutating func modeChanged() {
            error = nil
            if mode != .history { history.selectedID = nil }
            if mode != .manifest { manifest.request = nil; manifest.isImporting = false }
        }
    }

    private struct ManualDraft {
        var algorithm: IntegrityAlgorithm = .sha256
        var digest = ""
    }
    private struct HistoryDraft {
        var candidates: [IntegrityRecord] = []
        var selectedID: UUID?
        var generation = 0
        var error: String?
        var isLoading = false
    }
    private struct ManifestDraft {
        var imported: ImportedManifest?
        var isPresented = false
        var request: ImportRequest?
        var isImporting = false
    }
    private struct ImportedManifest {
        let document: IntegrityManifest
        let name: String
    }
    private struct CandidateRequest: Hashable {
        let account: AccountKey
        let reference: RemoteReference
        let size: Int64
        let session: ObjectIdentifier
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
        let folder: DownloadFolder
        let choice: Choice
    }

    init(target: DownloadConfirmationTarget, onSubmitted: @escaping @MainActor () -> Void) {
        self.target = target
        self.onSubmitted = onSubmitted
    }

    var body: some View {
        let candidate = candidateRequest
        VStack(spacing: 0) {
            HStack {
                Text("下载到本机").font(.headline)
                Spacer()
            }.padding()
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                source
                selectedItems
                FileSelectionSummary(entries: target.entries)
                integrityControls
                if !isContextCurrent {
                    errorLabel("网盘账号或登录状态已变化，请取消后在文件页重新选择。")
                }
                if let folderError { errorLabel(folderError) }
                if let error = integrity.error { errorLabel(error) }
            }.padding()
            Divider()
            HStack {
                DownloadFolderPicker(selection: $selectedFolder, error: $folderError)
                    .disabled(isSubmitting)
                Spacer()
                if isSubmitting { ProgressView().controlSize(.small) }
                Button("取消", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("下载", action: beginDownload)
                    .keyboardShortcut(.defaultAction)
                    .disabled(target.entries.isEmpty || !isContextCurrent || isSubmitting ||
                              integrity.manifest.isImporting || folderError != nil)
            }.padding()
        }
        .frame(minWidth: 600, idealWidth: 660)
        .task(id: candidate) { await loadCandidates(candidate) }
        .task(id: integrity.manifest.request?.id) {
            guard let request = integrity.manifest.request else { return }
            await importManifest(request)
        }
        .task(id: submission?.id) {
            guard let submission else { return }
            await download(submission)
        }
        .onChange(of: integrity.mode) { integrity.modeChanged() }
        .onChange(of: selectedFolder) { folderError = nil }
        .onChange(of: sessionIdentity) {
            if sessionIdentity != target.session { contextInvalidated = true }
        }
        .onDisappear { isCancelled = true }
        .fileImporter(isPresented: $integrity.manifest.isPresented, allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard isContextCurrent, integrity.mode == .manifest, !isSubmitting,
                      !isCancelled, let url = urls.first else { return }
                integrity.error = nil
                integrity.manifest.isImporting = true
                integrity.manifest.request = .init(url: url)
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    integrity.error = error.localizedDescription
                }
            }
        }
    }

    private var sessionIdentity: ObjectIdentifier? {
        model.coordinator.netdisks[target.account.provider].map(ObjectIdentifier.init)
    }
    private var isContextCurrent: Bool {
        !contextInvalidated && model.accountKey(for: target.account.provider) == target.account &&
        sessionIdentity == target.session
    }
    private var singleFile: RemoteEntry? {
        target.entries.count == 1 && !target.entries[0].isDirectory ? target.entries[0] : nil
    }
    private var candidateRequest: CandidateRequest? {
        guard integrity.mode == .history, isContextCurrent, let file = singleFile else { return nil }
        return .init(account: target.account, reference: file.reference, size: file.size, session: target.session,
                     reload: integrity.history.generation, integrityRevision: model.integrityRecordsRevision)
    }
    private var accountName: String {
        guard model.accountKey(for: target.account.provider) == target.account else { return target.account.accountID }
        return model.coordinator.accountNames[target.account.provider] ?? target.account.accountID
    }
    private var sourceDescription: String {
        if let description = target.pathDescription { return description }
        guard let directory = target.directory else { return "已选文件" }
        switch directory {
        case .baidu(let path, _): return path
        case .quark(let fid): return fid == "0" ? "根目录" : "已定位目录（ID：\(fid)）"
        }
    }
    private var source: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(target.account.provider.title) · \(accountName)").font(.subheadline.bold())
            Text(sourceDescription).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
    private var selectedItems: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 7) {
                ForEach(target.entries) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.isDirectory ? "folder" : "doc")
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                        Text(entry.name).lineLimit(1).truncationMode(.middle).help(entry.name)
                        Spacer()
                        if !entry.isDirectory { Text(entry.size.byteCount).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .frame(height: min(CGFloat(target.entries.count) * 26, 132))
    }

    private var integrityControls: some View {
        DisclosureGroup("内容校验", isExpanded: $showsIntegrity) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("校验依据", selection: $integrity.mode) {
                    Text(IntegrityMode.none.title).tag(IntegrityMode.none)
                    if singleFile != nil {
                        Text(IntegrityMode.manual.title).tag(IntegrityMode.manual)
                        Text(IntegrityMode.history.title).tag(IntegrityMode.history)
                    }
                    Text(IntegrityMode.manifest.title).tag(IntegrityMode.manifest)
                }.pickerStyle(.menu).fixedSize()
                switch integrity.mode {
                case .none:
                    Text("没有明确校验依据时，完成后显示“未验证源文件内容”。")
                        .font(.caption).foregroundStyle(.secondary)
                case .manual: manualInput
                case .history: historyInput
                case .manifest: manifestInput
                }
            }.padding(.top, 6)
        }
        .disabled(isSubmitting || !isContextCurrent)
    }
    private var manualInput: some View {
        HStack {
            Picker("算法", selection: $integrity.manual.algorithm) {
                Text("SHA-256").tag(IntegrityAlgorithm.sha256)
                Text("MD5").tag(IntegrityAlgorithm.md5)
            }.labelsHidden().frame(width: 110)
            TextField(integrity.manual.algorithm == .sha256 ? "64 位十六进制 SHA-256" : "32 位十六进制 MD5", text: $integrity.manual.digest)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
        }
    }
    @ViewBuilder private var historyInput: some View {
        Text("历史校验记录仅作为候选。请明确选择期望版本；不能据此认定云端内容仍未变化。")
            .font(.caption).foregroundStyle(.secondary)
        if integrity.history.isLoading { ProgressView("正在读取候选…").controlSize(.small) }
        else if let error = integrity.history.error {
            errorLabel(error)
            Button("重新读取候选") { integrity.history.generation += 1 }
        } else if integrity.history.candidates.isEmpty {
            Text("没有与账号、文件身份及大小匹配的已验证校验记录。")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("历史版本", selection: $integrity.history.selectedID) {
                Text("请选择期望版本").tag(UUID?.none)
                ForEach(integrity.history.candidates) { record in
                    if let expectation = record.expectation {
                        Text("\(record.verifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知时间") · \(expectation.algorithm == .sha256 ? "SHA-256" : "MD5") · \(expectation.origin.displayName) · \(expectation.digest.prefix(12))…")
                            .tag(Optional(record.id))
                    }
                }
            }
            if let selected = integrity.history.candidates.first(where: { $0.id == integrity.history.selectedID }),
               let expectation = selected.expectation {
                Text(expectation.digest).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
    private var manifestInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("导入 JSON 清单…") { integrity.manifest.isPresented = true }
                    .disabled(integrity.manifest.isImporting)
                if integrity.manifest.isImporting { ProgressView().controlSize(.small) }
                if let imported = integrity.manifest.imported {
                    Text("\(imported.name) · \(imported.document.entries.count) 项").lineLimit(1).truncationMode(.middle)
                    Button("清除") { integrity.manifest.imported = nil; integrity.mode = .none }
                }
            }
            Text("最多 4 MiB、10000 项。按完整相对路径及大小匹配；未列出的文件保持未验证。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadCandidates(_ request: CandidateRequest?) async {
        guard let request else {
            integrity.history.candidates = []; integrity.history.isLoading = false
            return
        }
        integrity.history.isLoading = true; integrity.history.error = nil
        do {
            try Task.checkCancellation()
            let result = try await model.integrityStore.candidates(account: request.account, reference: request.reference, size: request.size)
            try Task.checkCancellation()
            guard !isCancelled, candidateRequest == request else { return }
            integrity.history.candidates = result; integrity.history.isLoading = false
        } catch {
            guard !Task.isCancelled, !isCancelled, candidateRequest == request else { return }
            integrity.history.error = error.localizedDescription; integrity.history.isLoading = false
        }
    }

    private func importManifest(_ request: ImportRequest) async {
        do {
            let manifest = try await IntegrityManifestDocument.read(at: request.url)
            try Task.checkCancellation()
            guard !isCancelled, integrity.manifest.request?.id == request.id, integrity.mode == .manifest else { return }
            integrity.manifest.imported = .init(document: manifest, name: request.url.lastPathComponent)
            integrity.manifest.isImporting = false
        } catch {
            guard !Task.isCancelled, !isCancelled, integrity.manifest.request?.id == request.id else { return }
            integrity.manifest.imported = nil; integrity.error = error.localizedDescription
            integrity.manifest.isImporting = false
        }
    }

    /// 摘要与来源在提交前一次确认，格式错误不会引发远端枚举或创建下载任务。
    private func beginDownload() {
        guard !isSubmitting, !isCancelled, isContextCurrent, !integrity.manifest.isImporting,
              !target.entries.isEmpty, folderError == nil else { return }
        do {
            guard target.entries.allSatisfy({ $0.reference.provider == target.account.provider }) else {
                throw UploadRecordError.invalid("下载项目不属于此网盘，请返回文件页重新选择。")
            }
            let choice: Choice
            switch integrity.mode {
            case .none: choice = .none
            case .manual:
                guard let file = singleFile else { throw UploadRecordError.invalid("手输摘要只适用于一个文件") }
                let value = integrity.manual.digest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let length = integrity.manual.algorithm == .sha256 ? 64 : 32
                guard value.utf8.count == length,
                      value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw UploadRecordError.invalid("\(integrity.manual.algorithm == .sha256 ? "SHA-256" : "MD5") 应为 \(length) 位十六进制摘要")
                }
                _ = try IntegrityExpectation(algorithm: integrity.manual.algorithm, digest: value, origin: .userProvided,
                                             size: file.size, reference: file.reference)
                choice = .manual(integrity.manual.algorithm, value)
            case .history:
                guard let candidateID = integrity.history.selectedID,
                      let record = integrity.history.candidates.first(where: { $0.id == candidateID }) else {
                    throw UploadRecordError.invalid("请明确选择要比较的历史校验基准")
                }
                choice = .history(record)
            case .manifest:
                guard let manifest = integrity.manifest.imported?.document else {
                    throw UploadRecordError.invalid("请先导入校验清单")
                }
                choice = .manifest(manifest)
            }
            integrity.error = nil; isSubmitting = true
            submission = .init(folder: selectedFolder ?? model.currentFolder, choice: choice)
        } catch {
            integrity.error = error.localizedDescription; showsIntegrity = true
        }
    }

    /// 只有清单模式在入队前枚举；普通目录保持原有“先持久化任务、再枚举”的顺序。
    private func download(_ request: Submission) async {
        defer { isSubmitting = false }
        do {
            try Task.checkCancellation()
            guard !isCancelled, isContextCurrent else { throw UploadDestinationError.otherAccount }
            let disk = try model.netdisk(for: target.account.provider)
            guard disk.account == target.account, ObjectIdentifier(disk) == target.session else {
                throw UploadDestinationError.otherAccount
            }
            let bindings: [DownloadIntegrityBinding]
            switch request.choice {
            case .none: bindings = []
            case .manual(let algorithm, let digest):
                guard let file = singleFile else { throw UploadRecordError.invalid("摘要必须绑定单个文件") }
                let expectation = try IntegrityExpectation(algorithm: algorithm, digest: digest, origin: .userProvided,
                                                           size: file.size, reference: file.reference)
                bindings = [try DownloadIntegrityBinding(account: target.account, reference: file.reference, expectation: expectation)]
            case .history(let record):
                try record.validate()
                guard let file = singleFile, record.account == target.account,
                      record.reference == file.reference, record.status == .verified,
                      let original = record.expectation, original.size == file.size else {
                    throw UploadRecordError.invalid("历史校验记录与当前选择不匹配")
                }
                let expectation = try IntegrityExpectation(algorithm: original.algorithm, digest: original.digest,
                    origin: .userProvided, size: file.size, reference: file.reference, remoteVersion: record.remoteVersion)
                bindings = [try DownloadIntegrityBinding(account: target.account, reference: file.reference, expectation: expectation)]
            case .manifest(let manifest):
                let files = try await disk.files(in: target.entries)
                guard files.count <= IntegrityManifest.maximumEntries else {
                    throw UploadRecordError.invalid("单次清单校验最多选择 10000 个文件，请分批下载")
                }
                let selected = try files.map {
                    try IntegrityManifestFile(relativePath: $0.relativePath, size: $0.entry.size, reference: $0.entry.reference)
                }
                bindings = try manifest.bindings(account: target.account, files: selected)
            }
            try Task.checkCancellation()
            guard !isCancelled, isContextCurrent, submission?.id == request.id else {
                throw UploadDestinationError.otherAccount
            }
            try model.addNetdiskJob(entries: target.entries, account: target.account,
                                    downloadFolder: request.folder, integrityBindings: bindings)
            onSubmitted()
            dismiss()
        } catch {
            guard !Task.isCancelled, !isCancelled else { return }
            integrity.error = error.localizedDescription; showsIntegrity = true
        }
    }

    /// 同步标记取消，迟到的目录枚举和导入结果不能趁面板退出间隙创建任务。
    private func cancel() {
        isCancelled = true
        submission = nil
        integrity.manifest.request = nil
        dismiss()
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
    }
}
