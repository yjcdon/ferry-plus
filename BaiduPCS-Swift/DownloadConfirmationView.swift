import FerryCore
import SwiftUI

/// 文件页明确选中的来源；确认期间不再从可变的浏览选择重新取得下载对象。
struct DownloadConfirmationTarget: Identifiable {
    let id = UUID()
    let account: AccountKey
    let session: ObjectIdentifier
    let entries: [RemoteEntry]
}

/// 普通下载只确认所选文件与保存位置，枚举和内容检查继续由现有下载任务执行。
struct DownloadConfirmationView: View {
    let target: DownloadConfirmationTarget
    private let onSubmitted: @MainActor () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFolder: DownloadFolder?
    @State private var folderError: String?
    @State private var submissionError: String?
    @State private var contextInvalidated = false
    @State private var isFinished = false

    init(target: DownloadConfirmationTarget, onSubmitted: @escaping @MainActor () -> Void) {
        self.target = target
        self.onSubmitted = onSubmitted
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("下载到本机").font(.headline)
                Spacer()
            }.padding()
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                selectedItems
                if !isContextCurrent {
                    errorLabel("登录状态已变化，请关闭窗口后重新选择下载文件。")
                }
                if let folderError { errorLabel(folderError) }
                if let submissionError { errorLabel(submissionError) }
            }.padding()
            Divider()
            HStack {
                DownloadFolderPicker(selection: $selectedFolder, error: $folderError)
                Spacer()
                Button("取消", role: .cancel) {
                    isFinished = true
                    dismiss()
                }.keyboardShortcut(.cancelAction)
                Button("下载", action: beginDownload)
                    .keyboardShortcut(.defaultAction)
                    .disabled(target.entries.isEmpty || !isContextCurrent || isFinished || folderError != nil)
            }.padding()
        }
        .frame(minWidth: 600, idealWidth: 660)
        .onChange(of: selectedFolder) { folderError = nil }
        .onChange(of: sessionIdentity) {
            if sessionIdentity != target.session { contextInvalidated = true }
        }
        .onDisappear { isFinished = true }
    }

    private var sessionIdentity: ObjectIdentifier? {
        model.coordinator.netdisks[target.account.provider].map(ObjectIdentifier.init)
    }

    private var isContextCurrent: Bool {
        !contextInvalidated && model.accountKey(for: target.account.provider) == target.account &&
        sessionIdentity == target.session
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

    /// 用户确认后同步加入一次普通下载任务，不前置递归枚举，也不自动选择历史校验依据。
    private func beginDownload() {
        guard !isFinished, isContextCurrent, !target.entries.isEmpty, folderError == nil else { return }
        guard target.entries.allSatisfy({ $0.reference.provider == target.account.provider }) else {
            submissionError = "下载项目不属于此网盘，请返回文件页重新选择。"
            return
        }
        isFinished = true
        model.addNetdiskJob(entries: target.entries, account: target.account,
                            downloadFolder: selectedFolder ?? model.currentFolder)
        onSubmitted()
        dismiss()
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
    }
}
