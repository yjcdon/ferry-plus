import AppKit
import BaiduKit
import DownloadKit
import FerryCore
import SwiftUI

/// 详情栏：选中任务的详情和操作。选中多个任务时显示对它们的批量操作。
struct JobInspector: View {
    let jobs: [Job]
    /// 动作交回主窗口按当前筛选执行，不由详情保留的任务快照直接调度。
    let onAction: ([Job], JobAction) -> Void
    /// 请求移除任务。调用方决定是否先确认。
    let onRemove: ([Job], JobRemoval) -> Void
    let onVerify: (UUID, JobFile) -> Void

    var body: some View {
        switch jobs.count {
        case 0:
            ContentUnavailableView("未选择任务", systemImage: "sidebar.trailing")
        case 1:
            JobDetail(job: jobs[0], onAction: onAction, onRemove: { onRemove(jobs, $0) }, onVerify: onVerify)
                // 换任务时重新滚动到顶部。
                .id(jobs[0].id)
        default:
            MultipleSelection(jobs: jobs, onAction: onAction, onRemove: { onRemove(jobs, $0) })
        }
    }
}

/// 选中多个任务：数量和对这些任务的操作。和单个任务的详情一样，只列出可用的操作。
private struct MultipleSelection: View {
    let jobs: [Job]
    let onAction: ([Job], JobAction) -> Void
    let onRemove: (JobRemoval) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("已选择 \(jobs.count) 个任务", systemImage: "square.stack")
        } actions: {
            VStack {
                ForEach(JobAction.allCases, id: \.self) { action in
                    let targets = model.jobs(in: jobs, allowing: action)
                    if !targets.isEmpty {
                        Button {
                            onAction(targets, action)
                        } label: {
                            Text(action.title).frame(maxWidth: .infinity)
                        }
                    }
                }
                Button(role: .destructive) {
                    onRemove(.keepingFiles)
                } label: {
                    Text("移除").frame(maxWidth: .infinity)
                }
                .disabled(!jobs.contains { model.canOperate(on: $0) })
                if model.canTrashFiles(of: jobs) {
                    Button(role: .destructive) {
                        onRemove(.trashingFiles)
                    } label: {
                        Text("移除并删除文件").frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxWidth: 180)
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

/// 一个任务的详情。
private struct JobDetail: View {
    let job: Job
    let onAction: ([Job], JobAction) -> Void
    let onRemove: (JobRemoval) -> Void
    @Environment(AppModel.self) private var model
    let onVerify: (UUID, JobFile) -> Void

    var body: some View {
        // 不在这里读取进度，进度变化只让读取它的子视图刷新。
        let activity = model.coordinator.activity(of: job.id)
        let isRemoving = model.coordinator.removingJobs.contains(job.id)
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: job.systemImage)
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.title)
                            .font(.headline)
                            .textSelection(.enabled)
                        JobStatusText(job: job, activity: activity, isRemoving: isRemoving)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                JobProgressBar(job: job, activity: activity, isRemoving: isRemoving)
                JobNotes(job: job)
            }
            Section("统计") {
                JobStats(job: job, activity: activity)
            }
            Section("来源账号") {
                LabeledContent("网盘", value: job.provider.title)
                LabeledContent("账号", value: job.accountName ?? job.accountKey.map { "\(job.provider.title) · \($0.accountID)" } ?? "未记录账号")
                LabeledContent("创建时间", value: job.createdAt.formatted(date: .abbreviated, time: .standard))
            }
            Section("位置") {
                if let sourceLink = job.sourceLink {
                    LabeledContent("来源") {
                        HStack(spacing: 4) {
                            PathText(sourceLink)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(sourceLink, forType: .string)
                            } label: {
                                Label("拷贝链接", systemImage: "doc.on.doc")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("拷贝链接")
                        }
                    }
                }
                if let netdiskSource = job.netdiskSource {
                    LabeledContent("来源") { PathText(netdiskSource) }
                }
                if job.hasJobDirectory, !job.isCleanedUp {
                    LabeledContent("网盘") { PathText(job.remoteDirectory) }
                }
                LabeledContent("本地") {
                    PathText((job.downloadFolder ?? model.coordinator.downloadFolder).url.path(percentEncoded: false))
                }
            }
            if !job.files.isEmpty {
                Section("文件（\(job.files.count)）") {
                    ForEach(job.files) { file in
                        VStack(alignment: .leading, spacing: 6) {
                            FileRow(file: file, activity: model.coordinator.activity(ofFile: file.id))
                            if job.canVerifyCompletedFiles,
                               file.integrityExpectation?.origin == .userProvided || model.coordinator.verifyingLocalFiles.contains(file.id) {
                                if model.coordinator.verifyingLocalFiles.contains(file.id) {
                                    HStack {
                                        ProgressView().controlSize(.small)
                                        Text("正在校验本地文件").font(.caption)
                                        Button("取消") { Task { await model.coordinator.cancelLocalVerification(fileID: file.id) } }
                                    }
                                } else {
                                    Button(file.integrityExpectation == nil ? "校验本地文件" : "重新校验本地文件") { onVerify(job.id, file) }
                                        .buttonStyle(.borderless)
                                        .disabled(!model.canOperate(on: job) || job.files.contains { model.coordinator.verifyingLocalFiles.contains($0.id) })
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .edgeBar(.bottom) {
            HStack {
                if let action = job.primaryAction, action != .reveal {
                    JobActionButton(job: job, action: action, onAction: { onAction([$0], $1) })
                }
                if !job.revealURLs.isEmpty {
                    JobActionButton(job: job, action: .reveal, onAction: { onAction([$0], $1) })
                }
                Spacer(minLength: 0)
                // 点按钮只移除任务；删除文件在按钮的菜单中，是不常用的破坏性操作。
                Menu("移除") {
                    Button("移除并删除文件", role: .destructive) { onRemove(.trashingFiles) }
                        .disabled(!model.canTrashFiles(of: [job]))
                } primaryAction: {
                    onRemove(.keepingFiles)
                }
                .fixedSize()
                .disabled(!model.canOperate(on: job))
            }
            .labelStyle(.titleOnly)
            .padding()
        }
    }
}

/// 任务的状态文字。
private struct JobStatusText: View {
    let job: Job
    let activity: JobActivity
    let isRemoving: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(isRemoving
             ? "正在移除"
             : job.files.contains(where: { model.coordinator.verifyingLocalFiles.contains($0.id) }) ? "正在校验本地文件"
             : job.statusText(isRunning: activity.isRunning, cleansUp: model.settings.cleanupAfterDownload(for: job.provider)))
    }
}

/// 已下载 / 总大小、速度、剩余时间和文件完成数。没有值时显示“—”。
private struct JobStats: View {
    let job: Job
    let activity: JobActivity

    var body: some View {
        let progress = activity.progress
        let isDownloading = job.phase == .downloading && !job.isPaused
        Group {
            LabeledContent("已下载", value: job.files.isEmpty ? "—" : progress.sizeSummary)
            LabeledContent("速度", value: isDownloading ? progress.speedText ?? "—" : "—")
            LabeledContent("剩余时间", value: isDownloading ? progress.remainingTimeText ?? "—" : "—")
            LabeledContent("文件", value: job.files.isEmpty
                           ? "—" : "\(job.files.count(where: \.isCompleted)) / \(job.files.count)")
        }
        .monospacedDigit()
    }
}

/// 详情栏中的一个路径或链接：一行，中间截断，可以选择。悬停时显示全文。
private struct PathText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(text)
    }
}

/// 任务中的一个文件下载。只观察这个文件的状态。
private struct FileRow: View {
    let file: JobFile
    let activity: FileActivity

    var body: some View {
        let snapshot = activity.snapshot
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: FileIcon.systemName(for: file.name, isDirectory: false))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.relativePath)
                HStack(spacing: 6) {
                    if file.isCompleted {
                        Label("已完成", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                    } else if let snapshot {
                        if case .failed(let failure) = snapshot.state {
                            Label(failure.message, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(failure.message)
                        } else {
                            Text(snapshot.statusText)
                            ProgressView(value: fraction(snapshot))
                                .frame(maxWidth: 80)
                                .accessibilityHidden(true)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(file.size.byteCount)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if file.integrityStatus == .mismatch {
                    Text("文件内容不一致").font(.caption).foregroundStyle(.red)
                }
            }
        }
        .monospacedDigit()
    }

    private func fraction(_ snapshot: DownloadSnapshot) -> Double {
        let total = snapshot.totalBytes ?? file.size
        return total > 0 ? min(1, Double(snapshot.receivedBytes) / Double(total)) : 0
    }
}

extension Job {
    /// 来源分享链接。有提取码时放在 `pwd` 参数中，粘贴到“添加链接”时自动填入。网盘任务为 nil。
    var sourceLink: String? {
        guard let link else { return nil }
        let url = link.url.absoluteString
        guard let password = password ?? link.password else { return url }
        return "\(url)?pwd=\(password)"
    }

    /// 网盘任务的来源：勾选条目的网盘路径。勾选了多个条目时显示第一个和数量。分享任务为 nil。
    var netdiskSource: String? {
        guard case .netdisk(let entries) = source, let first = entries.first else { return nil }
        let path = entries.count == 1 ? first.path : "\(first.path) 等 \(entries.count) 项"
        return "我的网盘 · \(path)"
    }
}

/// 用户为本地完成文件明确提供摘要；可信原始依据只读，纠正用户输入需单独确认。
struct CompletedFileVerificationSheet: View {
    let jobID: UUID
    let file: JobFile
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var algorithm: IntegrityAlgorithm
    @State private var digest: String
    @State private var isSubmitting = false
    @State private var error: String?
    @State private var succeeded = false

    init(jobID: UUID, file: JobFile) {
        self.jobID = jobID
        self.file = file
        _algorithm = State(initialValue: file.integrityExpectation?.algorithm ?? .sha256)
        _digest = State(initialValue: file.integrityExpectation?.digest ?? "")
    }

    private var currentBasis: IntegrityExpectation? {
        model.coordinator.jobs.first(where: { $0.id == jobID })?.files.first(where: { $0.id == file.id })?.integrityExpectation
    }
    private var trustedBasis: Bool { currentBasis.map { $0.origin != .userProvided } ?? false }
    private var running: Bool { isSubmitting || model.coordinator.verifyingLocalFiles.contains(file.id) }
    private var changingUserBasis: Bool {
        guard let basis = currentBasis, basis.origin == .userProvided else { return false }
        return algorithm != basis.algorithm || digest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != basis.digest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("校验本地文件").font(.headline)
            Text(file.relativePath).lineLimit(2).textSelection(.enabled)
            Text("检查已下载的文件。")
                .font(.callout).foregroundStyle(.secondary)
            Picker("算法", selection: $algorithm) {
                Text("SHA-256").tag(IntegrityAlgorithm.sha256)
                Text("MD5").tag(IntegrityAlgorithm.md5)
            }.pickerStyle(.segmented).disabled(trustedBasis || running)
            TextField("输入原始文件摘要", text: $digest)
                .textFieldStyle(.roundedBorder).disabled(trustedBasis || running)
            if trustedBasis {
                Text("使用已记录的原始校验依据。").font(.caption).foregroundStyle(.secondary)
            } else if changingUserBasis {
                Text("将替换此前手动输入的摘要，并重新校验本地文件。").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if succeeded { Label("本地文件内容一致", systemImage: "checkmark.circle").foregroundStyle(.green) }
            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Text("正在校验").font(.callout)
                }
                Spacer()
                Button(running ? "取消校验" : "关闭") {
                    Task {
                        await model.coordinator.cancelLocalVerification(fileID: file.id)
                        dismiss()
                    }
                }.keyboardShortcut(.cancelAction)
                Button(changingUserBasis ? "更新摘要并校验" : "校验") {
                    error = nil; succeeded = false; isSubmitting = true
                    Task { @MainActor in
                        defer { isSubmitting = false }
                        do {
                            try await model.coordinator.verifyCompletedFile(jobID: jobID, fileID: file.id,
                                algorithm: algorithm, digest: digest, replacingUserProvided: changingUserBasis)
                            succeeded = true
                        } catch is CancellationError {
                            error = "校验已取消，可重试。"
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(running || digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 480)
        .interactiveDismissDisabled(running)
        .onDisappear { Task { await model.coordinator.cancelLocalVerification(fileID: file.id) } }
    }
}
