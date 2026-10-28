import DownloadKit
import FerryCore
import Foundation
import UniformTypeIdentifiers

extension IntegrityOrigin {
    /// 历史候选展示原始校验依据的来源，不能把用户指定值描述成上传原件。
    var displayName: String {
        switch self {
        case .localOriginal: "本地原始文件"
        case .remoteOriginal: "网盘原始摘要"
        case .userProvided: "用户指定摘要"
        }
    }
}

extension Int64 {
    var byteCount: String { formatted(.byteCount(style: .file)) }

}

extension JobProgress {
    /// 例如 “12 MB / 100 MB · 2 MB/s · 剩余 3分钟”。
    var sizeSummary: String { "\(receivedBytes.byteCount) / \(totalBytes.byteCount)" }

    var summary: String {
        var parts = [sizeSummary]
        if let speedText {
            parts.append(speedText)
        }
        if let remainingTimeText {
            parts.append("剩余 \(remainingTimeText)")
        }
        return parts.joined(separator: " · ")
    }

    /// 例如 “2 MB/s”。没有速度时为 nil。
    var speedText: String? {
        bytesPerSecond > 0 ? "\(Int64(bytesPerSecond).byteCount)/s" : nil
    }

    /// 例如 “3分钟”。无法估计时为 nil。
    var remainingTimeText: String? {
        remainingTime?.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
    }
}

extension Job {
    var isUnfinished: Bool { phase != .completed }

    /// 只有实际落盘且每个文件都有明确基准和成功校验结果，整批才能展示为已验证。
    var hasVerifiedContent: Bool {
        !files.isEmpty && files.allSatisfy {
            $0.isCompleted && $0.integrityStatus == .verified && $0.integrityExpectation != nil
        }
    }

    /// 来源是我的网盘。
    var isNetdisk: Bool {
        if case .netdisk = source { true } else { false }
    }

    /// `isRunning`：有文件正在下载（见 `JobActivity`）。`cleansUp`：设置中的清理开关。
    /// 网盘任务的第一步是准备，没有转存和清理。
    func statusText(isRunning: Bool, cleansUp: Bool) -> String {
        switch phase {
        case .transferring:
            return isNetdisk ? "准备中 · 正在列出文件…" : "正在转存…"
        case .downloading:
            if isPaused { return "已暂停" }
            if files.allSatisfy(\.isCompleted) {
                return cleansUp && hasJobDirectory ? "正在清理网盘中的转存文件…" : "正在完成…"
            }
            return isRunning ? "正在下载" : "等待下载"
        case .completed:
            return "已完成"
        case .failed(.transfer):
            return isNetdisk ? "准备失败" : "转存失败"
        case .failed(.download):
            return "下载失败"
        }
    }
}

extension DownloadSnapshot {
    var statusText: String {
        switch state {
        case .queued: "等待下载"
        case .running: bytesPerSecond > 0 ? "\(Int64(bytesPerSecond).byteCount)/s" : "正在下载"
        case .paused: "已暂停"
        case .completed: "已完成"
        case .failed(let failure): failure.message
        }
    }
}

enum FileIcon {
    static func systemName(for name: String, isDirectory: Bool) -> String {
        if isDirectory { return "folder" }
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return "doc" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .text) { return "doc.text" }
        if type.conforms(to: .application) || type.conforms(to: .diskImage) { return "shippingbox" }
        return "doc"
    }
}
