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
            var linkExpiry: RangeVerificationGate.ExpiryMetadata?
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
                    result.linkExpiry = try await verificationLinkExpiry(candidate, account: disk.account)
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

    struct ResumeReport: Encodable {
        struct Result: Encodable {
            let provider: String
            var totalBytes: Int64?
            var firstReceivedBytes: Int64?
            var restoredReceivedBytes: Int64?
            var finalReceivedBytes: Int64?
            var transferredBodyBytes: Int64 = 0
            var restoredState: String?
            var offsets: [Int64] = []
            var responses: [RangeVerificationGate.Evidence] = []
            var state = "not_started"
        }
        var results: [Result] = []
    }

    /// 两次正式暂停之间最多读取两片真实数据；只读账号源文件，隔离 partial 和状态保留在 .build 内。
    func verifyBoundedResume() async -> ResumeReport {
        await start()
        var report = ResumeReport()
        for provider in Provider.allCases {
            var result = ResumeReport.Result(provider: provider.rawValue)
            var current: JobCoordinator?
            var gates: [RangeVerificationGate] = []
            do {
                let disk = try netdisk(for: provider)
                guard let sample = try await boundedResumeSample(disk) else {
                    result.state = "no_sample_in_bounded_directories"
                    report.results.append(result)
                    continue
                }
                result.totalBytes = sample.size
                let directory = URL(filePath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".build/verification-resume/\(UUID().uuidString)/\(provider.rawValue)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory.appendingPathComponent("Files", isDirectory: true),
                                                        withIntermediateDirectories: true)
                let (first, firstGate) = makeResumeVerificationStack(directory: directory, disk: disk,
                                                                     lowerOffset: 0, totalSize: sample.size)
                current = first
                gates.append(firstGate)
                RangeVerificationProtocol.install(firstGate)
                await first.start()
                let job = first.addNetdiskJob(entries: [sample], account: disk.account)
                try await firstGate.waitForBoundary()
                await first.pause(job.id)
                let firstState = try resumeCheckpoint(first, jobID: job.id, directory: directory)
                guard firstState.receivedBytes == RangeVerificationGate.window else {
                    throw RangeVerificationFailure("first_checkpoint_mismatch")
                }
                result.firstReceivedBytes = firstState.receivedBytes
                await first.shutdown()
                current = nil
                let (second, secondGate) = makeResumeVerificationStack(directory: directory, disk: disk,
                    lowerOffset: firstState.receivedBytes, totalSize: sample.size)
                current = second
                gates.append(secondGate)
                RangeVerificationProtocol.install(secondGate)
                await second.start()
                let restored = try resumeCheckpoint(second, jobID: job.id, directory: directory)
                guard restored.receivedBytes == firstState.receivedBytes, secondGate.evidence.isEmpty else {
                    throw RangeVerificationFailure("restored_checkpoint_mismatch")
                }
                result.restoredReceivedBytes = restored.receivedBytes
                result.restoredState = "paused"
                await second.resume(job.id)
                try await secondGate.waitForBoundary()
                await second.pause(job.id)
                let final = try resumeCheckpoint(second, jobID: job.id, directory: directory)
                guard final.receivedBytes == 2 * RangeVerificationGate.window,
                      firstGate.evidence.first?.offset == 0,
                      secondGate.evidence.first?.offset == restored.receivedBytes else {
                    throw RangeVerificationFailure("resumed_checkpoint_mismatch")
                }
                result.finalReceivedBytes = final.receivedBytes
                result.offsets = final.offsets
                result.state = "verified"
            } catch let error as RangeVerificationFailure { result.state = error.status }
            catch { result.state = "verification_failed" }
            await current?.shutdown()
            RangeVerificationProtocol.install(nil)
            result.transferredBodyBytes = gates.reduce(0) { $0 + $1.bytes }
            result.responses = gates.flatMap(\.evidence)
            report.results.append(result)
        }
        return report
    }

    /// 只检查根目录及最多八个目录，优先应用转存目录；排除两片就完成的文件，以验证持续的 partial。
    private func boundedResumeSample(_ disk: any Netdisk) async throws -> RemoteEntry? {
        let root = try await disk.listDirectory(nil)
        func sample(_ entries: [RemoteEntry]) -> RemoteEntry? {
            entries.filter { !$0.isDirectory && $0.size > 2 * RangeVerificationGate.window && $0.size <= 64 * 1024 * 1024 }
                .min { $0.size < $1.size }
        }
        if let file = sample(root) { return file }
        let ownName = settings.transferFolder(for: disk.account.provider).split(separator: "/").last.map(String.init)
        let roots = root.filter(\.isDirectory)
        var pending = Array((roots.filter { $0.name == ownName } + roots.filter { $0.name != ownName }).prefix(8))
        var cursor = 0
        var visited = Set<RemoteReference>()
        while cursor < pending.count, visited.count < 8 {
            try Task.checkCancellation()
            let directory = pending[cursor]
            cursor += 1
            guard visited.insert(directory.reference).inserted else { continue }
            let children = try await disk.listDirectory(directory.reference)
            if let file = sample(children) { return file }
            // 同层优先，避免应用目录的深分支用尽全部八次查询。
            pending.append(contentsOf: children.filter(\.isDirectory).prefix(8))
        }
        return nil
    }

    private struct ResumeCheckpoint: Decodable {
        struct Segment: Decodable { let start: Int64; let received: Int64 }
        let segments: [Segment]
        let isPaused: Bool
        var receivedBytes: Int64 { segments.reduce(0) { $0 + $1.received } }
        var offsets: [Int64] { segments.filter { $0.received > 0 }.map { $0.start + $0.received } }
    }

    /// 只解码分片位移和暂停标记；不将持久记录内的文件名、下载上下文或凭据写入报告。
    private func resumeCheckpoint(_ coordinator: JobCoordinator, jobID: UUID, directory: URL) throws -> ResumeCheckpoint {
        guard let job = coordinator.jobs.first(where: { $0.id == jobID }), job.phase == .downloading,
              job.isPaused, let file = job.files.first,
              coordinator.downloads[file.id]?.state == .paused else { throw RangeVerificationFailure("not_paused") }
        let stateName = file.id.utf8.map { String(format: "%02x", $0) }.joined() + ".json"
        let url = directory.appendingPathComponent("Downloads", isDirectory: true).appendingPathComponent(stateName)
        let checkpoint = try JSONDecoder().decode(ResumeCheckpoint.self, from: Data(contentsOf: url))
        guard checkpoint.isPaused else { throw RangeVerificationFailure("pause_not_persisted") }
        return checkpoint
    }

    private static func verificationSample(_ entries: [RemoteEntry]) -> RemoteEntry? {
        entries.filter { !$0.isDirectory && $0.size > 0 && $0.size <= 2 * 1024 * 1024 }
            .min { $0.size < $1.size }
    }
}
#endif
