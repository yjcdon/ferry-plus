import AppKit
import FerryCore
import SwiftUI

/// 文件页已经确定的上传位置；确认面板不能重新选择网盘或悄悄恢复历史目录。
struct UploadConfirmationTarget: Identifiable {
    let id = UUID()
    let account: AccountKey
    let session: ObjectIdentifier
    let directory: RemoteReference
    /// nil 表示只有准确目录引用，未知祖先不能拼成完整路径。
    var trail: [RemoteEntry]? = nil
    var files: [URL] = []
    var accountName: String? = nil
}

/// 只确认本地项目、固定目标和同名策略；扫描及远端写入继续使用现有上传编排。
struct UploadConfirmationView: View {
    let target: UploadConfirmationTarget
    private let onSubmitted: @MainActor () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL]
    @State private var policy: UploadConflictPolicy = .keepBoth
    @State private var selectionError: String?
    @State private var submitError: String?
    @State private var preflight: UploadPreflightResult?
    @State private var checkedRequest: PreflightRequest?
    @State private var preflightError: String?
    @State private var isCheckingPreflight = false
    @State private var preflightGeneration = 0
    @State private var submission: Submission?
    @State private var isSubmitting = false
    @State private var isDropTarget = false
    @State private var authorizedFiles: [URL] = []
    @State private var panelPresenter = UploadOpenPanelPresenter()
    @State private var hasWindow = false
    @State private var openedInitialPicker = false

    private struct PreflightRequest: Hashable {
        let files: [URL]
        let policy: UploadConflictPolicy
        let generation: Int
    }

    private struct Submission: Identifiable {
        let id = UUID()
        let files: [URL]
        let policy: UploadConflictPolicy
    }

    init(target: UploadConfirmationTarget, onSubmitted: @escaping @MainActor () -> Void) {
        self.target = target
        self.onSubmitted = onSubmitted
        _files = State(initialValue: Self.uniqueLocalURLs(target.files.filter(\.isFileURL)))
        _selectionError = State(initialValue: target.files.contains(where: { !$0.isFileURL }) ? "请选择本地文件或文件夹。" : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("上传到网盘").font(.headline)
                Spacer()
            }.padding()
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                destination
                fileSelection
                conflictPolicy
                preflightContent
                if let submitError { errorLabel(submitError) }
            }.padding()
            Divider()
            HStack {
                Spacer()
                if isSubmitting { ProgressView().controlSize(.small) }
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button("上传", action: beginSubmission)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }.padding()
        }
        .frame(minWidth: 580, idealWidth: 640)
        .fixedSize(horizontal: false, vertical: true)
        .solidSheetSurface()
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: 3)
                    .padding(4).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !isSubmitting, isContextCurrent, !urls.isEmpty else { return false }
            Self.appendFiles(urls, files: $files, error: $selectionError)
            return urls.contains(where: \.isFileURL)
        } isTargeted: { isDropTarget = $0 }
        .task(id: preflightRequest) { await checkPreflight(preflightRequest) }
        .task(id: submission?.id) {
            guard let submission else { return }
            await submit(submission)
        }
        .onChange(of: files, initial: true) { _, urls in
            updateAccess(to: urls)
            submitError = nil
        }
        .onChange(of: policy) { submitError = nil }
        .background(WindowReader(window: Binding(
            get: { panelPresenter.parentWindow }, set: {
                panelPresenter.parentWindow = $0
                hasWindow = $0 != nil
            }
        )))
        .task(id: hasWindow) {
            guard hasWindow, !openedInitialPicker else { return }
            openedInitialPicker = true
            if files.isEmpty { chooseFiles() }
        }
        .onDisappear {
            panelPresenter.cancel()
            releaseAccess()
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(target.account.provider.title).font(.subheadline.bold())
            Text("账号：\(accountName)")
            Text("目标：\(destinationTitle)")
                .lineLimit(3).textSelection(.enabled)
            if !isContextCurrent {
                errorLabel("登录状态已变化，请关闭窗口后重新选择上传位置。")
            }
        }.font(.caption).foregroundStyle(.secondary)
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
                                } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .help("移除此项目").disabled(isSubmitting)
                            }
                        }
                    }
                }.frame(height: min(CGFloat(files.count) * 25, 125))
            }
            Button(action: chooseFiles) {
                VStack(spacing: 4) {
                    Text(files.isEmpty ? "点击选择文件或文件夹，也可拖到这里" : "点击继续添加文件或文件夹")
                    Text("应用程序等包文件将作为文件夹上传").font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: files.isEmpty ? 70 : 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || !isContextCurrent)
            .accessibilityLabel("选择文件或文件夹")
            if let selectionError { errorLabel(selectionError) }
        }
    }

    private var conflictPolicy: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("同名文件")
                Picker("同名文件", selection: $policy) {
                    Text("保留两份").tag(UploadConflictPolicy.keepBoth)
                    Text("跳过").tag(UploadConflictPolicy.skip)
                    if target.account.provider == .baidu {
                        Text("覆盖（保留旧版本）").tag(UploadConflictPolicy.replace)
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .disabled(isSubmitting || !isContextCurrent)
                Spacer()
            }
            if policy == .replace {
                Text("覆盖时会保留旧版本。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var preflightContent: some View {
        if isCheckingPreflight {
            ProgressView("正在检查文件及目标容量").controlSize(.small)
        } else if let preflightError {
            errorLabel(preflightError)
            Button("重新检查") { preflightGeneration += 1 }
                .disabled(isSubmitting || !isContextCurrent)
        } else if let result = preflight {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(result.summary.fileCount) 个文件 · \(result.summary.directoryCount) 个文件夹 · \(ByteCountFormatter.string(fromByteCount: result.summary.totalBytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                if result.spaceEstimateOverflow {
                    errorLabel("所选文件所需空间过大，请减少上传内容后重试。")
                } else if result.insufficientSpace {
                    errorLabel("目标剩余容量不足，请清理空间或减少本次上传内容。")
                }
                if result.summary.issueCount > 0 {
                    errorLabel("所选文件中有 \(result.summary.issueCount) 项需要处理，请调整后重新检查。")
                    ForEach(Array(result.summary.issues.enumerated()), id: \.offset) { _, message in
                        errorLabel(message)
                    }
                    if result.summary.issueCount > result.summary.issues.count {
                        Text("仅显示前 20 个问题。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if result.summary.issueCount > 0 || result.insufficientSpace {
                    Button("重新检查") { preflightGeneration += 1 }
                        .disabled(isSubmitting || !isContextCurrent)
                }
            }
        }
    }

    private var isContextCurrent: Bool {
        target.directory.provider == target.account.provider &&
        model.accountKey(for: target.account.provider) == target.account &&
        model.coordinator.netdisks[target.account.provider].map(ObjectIdentifier.init) == target.session
    }

    private var accountName: String {
        if let name = target.accountName { return name }
        guard isContextCurrent else { return target.account.accountID }
        return model.coordinator.accountNames[target.account.provider] ?? target.account.accountID
    }

    private var destinationTitle: String {
        if target.directory == target.account.provider.rootReference { return "根目录" }
        if let trail = target.trail, trail.last?.reference == target.directory {
            return "根目录 / " + trail.map(\.name).joined(separator: " / ")
        }
        switch target.directory {
        case .baidu(let path, _): return path
        case .quark: return "根目录 / … / 当前文件夹"
        }
    }

    private var preflightRequest: PreflightRequest? {
        guard isContextCurrent, !files.isEmpty else { return nil }
        return .init(files: files, policy: policy, generation: preflightGeneration)
    }

    private var canSubmit: Bool {
        isContextCurrent && !isSubmitting && !files.isEmpty && !isCheckingPreflight &&
        (policy != .replace || target.account.provider == .baidu) &&
        checkedRequest == preflightRequest && preflight?.canUpload == true
    }

    /// 只做可取消的源元数据、容量和目录读取；目标身份失效后不发布过期检查结果。
    private func checkPreflight(_ request: PreflightRequest?) async {
        preflight = nil; checkedRequest = nil; preflightError = nil; isCheckingPreflight = request != nil
        guard let request else { return }
        do {
            let summary = try await UploadPreflight.inspect(request.files)
            try Task.checkCancellation()
            guard request == preflightRequest else { return }
            var available: Int64?, capacityReason: String?
            do { available = try await model.uploadAvailableBytes(for: target.account) }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                capacityReason = error.localizedDescription
            }
            guard isContextCurrent else { throw UploadDestinationError.otherAccount }
            let environment = try model.uploadEnvironment(for: target.account)
            let entries = try await environment.listDirectory(target.directory)
            try Task.checkCancellation()
            guard request == preflightRequest else { return }
            preflight = UploadPreflight.evaluate(summary, entries: entries, policy: request.policy,
                                                  availableBytes: available, capacityReason: capacityReason)
            checkedRequest = request
            isCheckingPreflight = false
        } catch {
            guard !Task.isCancelled, request == preflightRequest else { return }
            preflightError = error.localizedDescription; isCheckingPreflight = false
        }
    }

    /// 用户确认后冻结本地项目和策略；目标始终来自打开面板时的账号和准确目录。
    private func beginSubmission() {
        guard canSubmit else { return }
        submitError = nil; isSubmitting = true
        submission = .init(files: files, policy: policy)
    }

    private func submit(_ request: Submission) async {
        defer { isSubmitting = false }
        do {
            try Task.checkCancellation()
            guard isContextCurrent else { throw UploadDestinationError.otherAccount }
            try await model.addUpload(files: request.files, account: target.account, destination: target.directory,
                                      conflictPolicy: request.policy)
            onSubmitted()
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            submitError = error.localizedDescription
        }
    }

    /// 选择面板只增加本地项目，提交授权书签之前由本确认页保持已取得的读取权限。
    private func chooseFiles() {
        let files = $files, error = $selectionError
        guard let window = panelPresenter.parentWindow else {
            error.wrappedValue = "请重新打开上传窗口。"
            return
        }
        panelPresenter.present(in: window) { urls in Self.appendFiles(urls, files: files, error: error) }
    }

    private func updateAccess(to urls: [URL]) {
        for url in authorizedFiles where !urls.contains(url) { url.stopAccessingSecurityScopedResource() }
        authorizedFiles.removeAll { !urls.contains($0) }
        for url in urls where !authorizedFiles.contains(url) {
            if url.startAccessingSecurityScopedResource() { authorizedFiles.append(url) }
        }
    }

    private func releaseAccess() {
        for url in authorizedFiles { url.stopAccessingSecurityScopedResource() }
        authorizedFiles = []
    }

    private static func appendFiles(_ urls: [URL], files: Binding<[URL]>, error: Binding<String?>) {
        error.wrappedValue = urls.contains(where: { !$0.isFileURL }) ? "请选择本地文件或文件夹。" : nil
        files.wrappedValue = uniqueLocalURLs(files.wrappedValue + urls.filter(\.isFileURL))
    }

    private static func uniqueLocalURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
    }
}

/// 选择器绑定触发窗口，页面消失时取消；回调不强持有 presenter。
@MainActor
private final class UploadOpenPanelPresenter {
    weak var parentWindow: NSWindow?
    private var panel: NSOpenPanel?

    func present(in window: NSWindow, onChoose: @escaping @MainActor ([URL]) -> Void) {
        guard panel == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true; panel.canCreateDirectories = false
        panel.prompt = "添加"
        self.panel = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
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
