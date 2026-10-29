import BaiduKit
import FerryCore
import QuarkKit
import SwiftUI

/// 添加链接：输入链接和提取码并打开分享，在文件树中勾选要下载的文件，然后下载。
///
/// 从剪贴板填入链接后立即打开分享。打开前，回车触发“打开”；打开后，回车触发“下载”。打开后修改链接或提取码，文件树清空。
struct AddLinkView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var linkText = ""
    @State private var password = ""
    /// 分享需要提取码或提取码错误时，焦点移到提取码框。
    @FocusState private var isPasswordFocused: Bool
    /// 从剪贴板自动填入的链接和提取码。用户改了链接以后不再显示提示。
    @State private var pasted: (link: String, password: String)?
    @State private var openTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var share: OpenedShare?
    @State private var isSubmitting = false
    /// nil 表示设置中的下载目录。
    @State private var selectedFolder: DownloadFolder?
    @State private var folderError: String?

    private var isOpening: Bool { openTask != nil }
    private var canOpen: Bool { !linkText.trimmingCharacters(in: .whitespaces).isEmpty && !isOpening }

    var body: some View {
        VStack(spacing: 0) {
            linkFields
                .padding()
            Divider()
            shareContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding()
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 460, idealHeight: 540)
        .task { await fillFromPasteboard() }
        // 关闭 sheet 时取消正在打开的分享。
        .onDisappear { openTask?.cancel(); releaseShare() }
    }

    private var linkFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("分享链接", text: $linkText, prompt: Text("百度或夸克分享链接"))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .onChange(of: linkText) {
                        fillPassword()
                        closeShare()
                    }
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first, let link = DiskShareLink.parse(text) else { return }
                    fillAndOpen(link)
                }
                .labelStyle(.iconOnly)
                .help("粘贴分享链接")
                LabeledContent("提取码") {
                    TextField("提取码", text: $password, prompt: Text("4 位"))
                        .labelsHidden()
                        .autocorrectionDisabled()
                        .frame(width: 64)
                        .focused($isPasswordFocused)
                        .onChange(of: password) { closeShare() }
                }
                Button("打开", action: openShare)
                    .keyboardShortcut(share == nil ? .defaultAction : nil)
                    .disabled(!canOpen)
            }
            .disabled(isOpening)
            if let link = DiskShareLink.parse(linkText) {
                let account = model.accountKey(for: link.provider)
                Label {
                    Text("\(link.provider.title) · \(account == nil ? "待登录" : model.coordinator.accountNames[link.provider] ?? "已登录账号")")
                } icon: {
                    ProviderIcon(provider: link.provider, size: 16)
                }
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let pasteHint {
                Label(pasteHint, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pasteHint: String? {
        guard let pasted, pasted.link == linkText else { return nil }
        return !pasted.password.isEmpty && pasted.password == password ? "已从剪贴板填入链接和提取码" : "已从剪贴板填入链接"
    }

    @ViewBuilder
    private var shareContent: some View {
        if let share {
            ShareBrowser(tree: share.tree)
                .id(ObjectIdentifier(share.tree))
        } else if isOpening {
            ProgressView("正在打开分享")
        } else if let errorMessage {
            ContentUnavailableView {
                Label("分享打开失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                if let link = DiskShareLink.parse(linkText), model.accountKey(for: link.provider) == nil {
                    Button("登录\(link.provider.title)") { model.presentLogin(for: link.provider) }
                }
                // 未登录或链接无效时，重试不会成功。
                if DiskShareLink.parse(linkText) != nil {
                    Button("重试", action: openShare)
                        .disabled(!canOpen)
                }
            }
        } else {
            ContentUnavailableView {
                Label("打开分享链接", systemImage: "link")
            } description: {
                Text("粘贴百度或夸克网盘分享链接，点击“打开”或按回车键。链接带提取码时自动填入。")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading) {
            if let share {
                FileSelectionSummary(entries: share.tree.selectedEntries)
            }
            if let folderError {
                Label(folderError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            HStack {
                DownloadFolderPicker(selection: $selectedFolder, error: $folderError)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("下载", action: download)
                    .keyboardShortcut(share == nil ? nil : .defaultAction)
                    .disabled(share?.tree.selection.isEmpty ?? true || isSubmitting)
            }
        }
    }

    /// 剪贴板检测结束后复核视图任务，关闭窗口不再启动分享请求。
    private func fillFromPasteboard() async {
        guard linkText.isEmpty, let link = await model.shareLinkOnPasteboard(),
              !Task.isCancelled, linkText.isEmpty else { return }
        fillAndOpen(link)
        pasted = (linkText, password)
    }

    private func fillAndOpen(_ link: DiskShareLink) {
        linkText = link.url.absoluteString
        password = link.password ?? ""
        openShare()
    }

    private func fillPassword() {
        if password.isEmpty, let found = DiskShareLink.parse(linkText)?.password {
            password = found
        }
    }

    /// 链接或提取码变了，已打开的分享不再对应它们：清空文件树，回到打开前的状态。
    /// 打开期间输入框不可用，这时的变化来自填入后立即打开，不清空。
    private func closeShare() {
        guard !isOpening else { return }
        releaseShare()
        errorMessage = nil
    }

    /// 在启动任务之前就进入“正在打开”状态，连按也只打开一次。
    private func openShare() {
        guard !isOpening else { return }
        releaseShare()
        guard let link = DiskShareLink.parse(linkText) else {
            errorMessage = "请输入有效的百度或夸克网盘分享链接。"
            return
        }
        errorMessage = nil
        let password = password
        openTask = Task {
            defer { openTask = nil }
            var openedDisk: (any Netdisk)?
            do {
                let disk = try model.netdisk(for: link.provider)
                openedDisk = disk
                let session = try await disk.openShare(link, password: password)
                guard !Task.isCancelled, model.accountKey(for: session.account.provider) == session.account else {
                    await disk.releaseShare(session)
                    return
                }
                let tree = FileTree<RemoteEntry>(initialSelection: .all) { directory in
                    try await disk.listShare(session, directory: directory)
                } onError: { [model] in model.noteError($0, from: disk) }
                share = OpenedShare(session: session, disk: disk, tree: tree)
                await tree.load(tree.root)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if let openedDisk { model.noteError(error, from: openedDisk) }
                errorMessage = error.localizedDescription
                let needsBaiduCode = (error as? BaiduError).map { [.passwordRequired, .wrongPassword].contains($0) } ?? false
                let needsQuarkCode = (error as? QuarkError).map { [.shareRequiresCode, .invalidPasscode].contains($0) } ?? false
                if needsBaiduCode || needsQuarkCode {
                    // 先结束“正在打开”，提取码框可用后才能获得焦点。
                    openTask = nil
                    isPasswordFocused = true
                }
            }
        }
    }

    private func download() {
        guard let share, !share.tree.selection.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        guard model.accountKey(for: share.session.account.provider) == share.session.account else {
            errorMessage = "账号已变化，请重新打开分享。"
            releaseShare()
            isSubmitting = false
            return
        }
        model.addJob(session: share.session, entries: share.tree.selectedEntries, downloadFolder: selectedFolder)
        dismiss()
    }

    private func releaseShare() {
        if let share { Task { await share.disk.releaseShare(share.session) } }
        share = nil
    }
}

/// 已打开的分享会话和它的文件树。
private struct OpenedShare {
    let session: DiskShareSession
    let disk: any Netdisk
    let tree: FileTree<RemoteEntry>
}

/// 分享的文件树：表头的全选和文件列表。
private struct ShareBrowser: View {
    let tree: FileTree<RemoteEntry>
    @State private var retryAttempt = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // 两个来源：全部勾选、有勾选。只勾选了一部分时，复选框显示为混合状态。
                Toggle("全选", sources: [
                    Binding(get: { tree.isAllSelected }, set: { tree.setAllSelected($0) }),
                    Binding(get: { !tree.selection.isEmpty }, set: { tree.setAllSelected($0) }),
                ], isOn: \.self)
                    .toggleStyle(FileSelectionToggleStyle())
                    .disabled(tree.root.children?.isEmpty ?? true)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: retryAttempt) {
            guard retryAttempt > 0 else { return }
            await tree.load(tree.root)
        }
    }

    @ViewBuilder
    private var content: some View {
        let root = tree.root
        if let children = root.children {
            if children.isEmpty {
                ContentUnavailableView("分享目录为空", systemImage: "folder")
            } else {
                List {
                    ForEach(children) { node in
                        FileTreeRow(node: node, tree: tree, isIncluded: false)
                    }
                }
            }
        } else if let error = root.loadError {
            ContentUnavailableView {
                Label("分享读取失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { retryAttempt += 1 }
            }
        } else {
            ProgressView("加载中")
        }
    }
}
