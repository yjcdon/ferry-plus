import BaiduKit
import FerryCore
import SwiftUI

/// 从我的网盘下载：在网盘的文件树中勾选文件或目录，然后下载。打开时不勾选任何条目。
///
/// “重新加载”换一棵新的文件树，从根目录重新读取，勾选清空。登录的账号变化时（设置窗口中可以退出登录再登录）也这样：
/// 文件树中的条目是原来账号的网盘中的路径。
struct NetdiskDownloadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tree: FileTree<RemoteEntry>?
    /// 文件树所属账号。新任务记录这个账号。
    @State private var treeAccount: AccountKey?
    @State private var provider: Provider = .baidu
    /// 每次重新加载加一。它变化时 `.task` 取消上一次读取，重新读取。
    @State private var generation = 0
    /// 没有文件树的原因，例如未登录。
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    /// nil 表示设置中的下载目录。
    @State private var selectedFolder: DownloadFolder?
    @State private var folderError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()
            Picker("网盘", selection: $provider) {
                ForEach(Provider.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.bottom)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding()
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 460, idealHeight: 540)
        .task(id: generation) { await load() }
        .onChange(of: sessionIdentity) { generation += 1 }
        .onChange(of: provider) {
            tree = nil
            treeAccount = nil
            errorMessage = nil
            generation += 1
        }
    }

    /// 同账号重新登录和代理更新也会撤销旧适配器，文件树必须使用新的会话。
    private var sessionIdentity: ObjectIdentifier? {
        guard let disk = model.coordinator.netdisks[provider] else { return nil }
        return ObjectIdentifier(disk)
    }

    private var header: some View {
        HStack {
            Text("从我的网盘下载")
                .font(.headline)
            Spacer()
            Button {
                generation += 1
            } label: {
                Label("重新加载", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("重新加载")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let tree {
            NetdiskBrowser(tree: tree, transferFolder: model.settings.transferFolder(for: provider))
                .id(ObjectIdentifier(tree))
        } else if let errorMessage {
            ContentUnavailableView {
                Label("无法读取网盘", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                if model.accountKey(for: provider) == nil {
                    Button("登录\(provider.title)…") { model.presentLogin(for: provider) }
                }
            }
        } else {
            ProgressView("正在读取网盘…")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading) {
            if let tree { FileSelectionSummary(entries: tree.selectedEntries) }
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
                    .keyboardShortcut(.defaultAction)
                    .disabled(tree?.selection.isEmpty ?? true || isSubmitting)
            }
        }
    }

    /// 每棵文件树固定来源和账号；切换 Tab 或换号后丢弃旧选择。
    private func load() async {
        tree = nil
        treeAccount = nil
        let provider = self.provider
        do {
            let disk = try model.netdisk(for: provider)
            let key = disk.account
            errorMessage = nil
            // 只捕获模型，避免闭包持有整个视图及其保存文件树的 State，形成引用环。
            let tree = FileTree<RemoteEntry>(initialSelection: .none) { [model] directory in
                guard model.accountKey(for: provider) == key else { throw CancellationError() }
                let entries = try await disk.listDirectory(directory?.reference)
                try Task.checkCancellation()
                guard model.accountKey(for: provider) == key else { throw CancellationError() }
                return entries
            } onError: { [model] in model.noteError($0, from: disk) }
            self.tree = tree
            treeAccount = key
            await tree.load(tree.root)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func download() {
        guard let tree, !tree.selection.isEmpty, !isSubmitting,
              let key = treeAccount, key == model.accountKey(for: key.provider) else { return }
        isSubmitting = true
        model.addNetdiskJob(entries: tree.selectedEntries, account: key, downloadFolder: selectedFolder)
        dismiss()
    }

}

/// 网盘的文件树：名称、修改日期和大小三列。
private struct NetdiskBrowser: View {
    let tree: FileTree<RemoteEntry>
    /// 设置中的转存目录。树中的这个目录显示“转存目录”标签。
    let transferFolder: String
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
                                FileTreeRow(node: node, tree: tree, isIncluded: false, badge: badge, columns: columns)
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
