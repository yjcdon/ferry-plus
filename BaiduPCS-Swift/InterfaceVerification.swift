#if DEBUG
import CryptoKit
import DownloadKit
import FerryCore
import Foundation

/// 使用 App 自身会话、适配器和下载引擎做只读样例验证，不导出 Cookie 或签名直链。
extension AppModel {
    struct InterfaceReport: Encodable {
        struct Result: Encodable {
            let provider: String
            var authenticated = false
            var rootEntries = 0
            var sampleBytes: Int64?
            var downloadedBytes: Int64?
            var sha256: String?
            var problem: String?
        }
        var results: [Result] = []
    }

    /// 自动选择少量目录中的小文件，调用正式任务链路；本地样例保留在独立验证目录。
    func verifyInterfaces() async -> InterfaceReport {
        await start()
        var report = InterfaceReport()
        for provider in Provider.allCases {
            var result = InterfaceReport.Result(provider: provider.rawValue)
            do {
                let disk = try netdisk(for: provider)
                let root = try await disk.listDirectory(nil)
                result.authenticated = true
                result.rootEntries = root.count
                var candidate = Self.verificationSample(root)
                var pending = Array(root.filter(\.isDirectory).prefix(8))
                var visited = Set<RemoteReference>()
                while candidate == nil, let directory = pending.popLast(), visited.count < 8 {
                    try Task.checkCancellation()
                    guard visited.insert(directory.reference).inserted else { continue }
                    let children = try await disk.listDirectory(directory.reference)
                    candidate = Self.verificationSample(children)
                    pending.append(contentsOf: children.filter(\.isDirectory).prefix(8))
                }
                if let candidate {
                    result.sampleBytes = candidate.size
                    let directory = URL(filePath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent(".build/verification/\(UUID().uuidString)/\(provider.rawValue)", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let job = coordinator.addNetdiskJob(entries: [candidate], account: disk.account,
                                                       downloadFolder: DownloadFolder(url: directory))
                    let deadline = ContinuousClock.now.advanced(by: .seconds(150))
                    while ContinuousClock.now < deadline {
                        try Task.checkCancellation()
                        guard let current = coordinator.jobs.first(where: { $0.id == job.id }) else { break }
                        if current.phase == .completed, let file = current.files.first, let url = file.localURL {
                            let data = try Data(contentsOf: url)
                            result.downloadedBytes = Int64(data.count)
                            result.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                            break
                        }
                        if case .failed = current.phase {
                            result.problem = current.error ?? "样例任务失败"
                            break
                        }
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    if result.downloadedBytes == nil, result.problem == nil { result.problem = "样例任务等待超时，进度已保留" }
                    // 验证使用自己的任务，不留测试记录混入用户列表；源文件从未写入或删除。
                    _ = await coordinator.remove(job.id, cleanupConfirmed: false)
                } else { result.problem = "已读取目录，限定范围内没有可验证的小文件" }
            } catch { result.problem = error.localizedDescription }
            report.results.append(result)
        }
        return report
    }

    private static func verificationSample(_ entries: [RemoteEntry]) -> RemoteEntry? {
        entries.filter { !$0.isDirectory && $0.size > 0 && $0.size <= 2 * 1024 * 1024 }
            .min { $0.size < $1.size }
    }
}
#endif
