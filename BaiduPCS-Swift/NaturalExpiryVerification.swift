#if DEBUG
import CryptoKit
import DownloadKit
import FerryCore
import Foundation

/// 仅为本次诊断保存旧链接，重放一次后立即交回正式账号来源；从不编码链接或请求头。
actor NaturalExpirySource: DownloadSource {
    private let base: any DownloadSource
    private var captured: ResolvedURL?
    private var replay = false
    private var replayCount = 0
    private var refreshCount = 0
    init(base: any DownloadSource) { self.base = base }

    func resolve(_ request: DownloadRequest) async throws -> ResolvedURL {
        if replay, let captured {
            replay = false
            replayCount += 1
            return captured
        }
        let link = try await base.resolve(request)
        if captured == nil { captured = link }
        else { refreshCount += 1 }
        return link
    }
    func oldLink() throws -> ResolvedURL {
        guard let captured else { throw RangeVerificationFailure("link_not_captured") }
        return captured
    }
    func prepareReplay() { replay = true; replayCount = 0; refreshCount = 0 }
    func counts() -> (replays: Int, refreshes: Int) { (replayCount, refreshCount) }
}

nonisolated struct NaturalExpiryContext: Sendable {
    let directory: URL
    let request: DownloadRequest
    let source: NaturalExpirySource
    let network: URLSessionConfiguration
    static let prefix: Int64 = 64 << 10
    func engine(guarding gate: RangeVerificationGate? = nil, stateFolder: String = "Downloads") -> DownloadEngine {
        let network = network.copy() as! URLSessionConfiguration
        network.protocolClasses = gate == nil ? [] : [RangeVerificationProtocol.self]
        let configuration = DownloadConfiguration(maxConcurrentFiles: 1, segmentsPerFile: 1,
            segmentSize: .fixed(Self.prefix), maxRetries: gate == nil ? 3 : 0,
            retryBaseDelay: .seconds(1), retryMaxDelay: .seconds(3),
            progressInterval: .milliseconds(250), checkpointInterval: .seconds(30))
        return DownloadEngine(stateDirectory: directory.appendingPathComponent(stateFolder), source: source,
            configuration: configuration, sessionConfiguration: network)
    }
}

extension AppModel {
    struct NaturalExpiryReport: Encodable {
        struct Result: Encodable {
            let provider: String
            var state = "not_started"
            var host: String?
            var capturedAt: Date?
            var waitUntil: Date?
            var candidateSeconds: Int64?
            var totalBytes: Int64?
            var receivedBytes: Int64?
            var prefixSHA256: String?
            var oldHTTPStatus: Int?
            var oldReplayCount = 0
            var freshResolveCount = 0
            var sha256: String?
            var sourceSHA256: String?
        }
        var phase = "preparing"
        var observedAt = Date()
        var results: [Result] = []
    }

    /// 保留 64 KiB 后关闭引擎，按真实候选时间只等待一次；最多十二小时，不制造过期。
    func verifyNaturalExpiry(smoke: Bool = false, progress: (NaturalExpiryReport) -> Void) async -> NaturalExpiryReport {
        await start()
        var report = NaturalExpiryReport()
        var contexts: [Provider: NaturalExpiryContext] = [:]
        let run = URL(filePath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/verification-natural-expiry/\(UUID().uuidString)")
        for provider in Provider.allCases {
            var result = NaturalExpiryReport.Result(provider: provider.rawValue)
            var current: DownloadEngine?
            do {
                let disk = try netdisk(for: provider)
                guard let sample = try await naturalExpirySample(disk) else {
                    result.state = "no_sample_in_bounded_directories"
                    report.results.append(result)
                    continue
                }
                let context = try naturalExpiryContext(sample, account: disk.account,
                    directory: run.appendingPathComponent(provider.rawValue))
                let gate = RangeVerificationGate(lowerOffset: 0, totalSize: sample.size,
                    configuration: context.network, window: NaturalExpiryContext.prefix)
                let engine = context.engine(guarding: gate)
                current = engine
                RangeVerificationProtocol.install(gate)
                try await engine.enqueue(context.request)
                try await gate.waitForBoundary()
                await engine.pause(id: context.request.id)
                let snapshot = await engine.snapshot(id: context.request.id)
                guard snapshot?.state == .paused, snapshot?.receivedBytes == NaturalExpiryContext.prefix else {
                    throw RangeVerificationFailure("prefix_checkpoint_mismatch")
                }
                await engine.shutdown()
                current = nil
                RangeVerificationProtocol.install(nil)
                guard try Self.naturalSavedOffset(context) == NaturalExpiryContext.prefix else {
                    throw RangeVerificationFailure("prefix_not_persisted")
                }
                let prefix = try Self.naturalPartialData(context)
                guard prefix.count == NaturalExpiryContext.prefix else { throw RangeVerificationFailure("partial_length_mismatch") }
                result.prefixSHA256 = SHA256.hash(data: prefix).map { String(format: "%02x", $0) }.joined()
                let link = try await context.source.oldLink()
                let metadata = RangeVerificationGate.expiryMetadata(link.url)
                result.host = metadata.host
                result.capturedAt = Date()
                result.candidateSeconds = metadata.candidateExpirySeconds
                result.totalBytes = sample.size
                result.receivedBytes = snapshot?.receivedBytes
                result.state = "prefix_saved"
                contexts[provider] = context
            } catch is CancellationError { result.state = "cancelled" }
            catch let error as RangeVerificationFailure { result.state = error.status }
            catch { result.state = "prefix_verification_failed" }
            await current?.shutdown()
            RangeVerificationProtocol.install(nil)
            report.results.append(result)
            report.observedAt = Date()
            progress(report)
        }
        if Task.isCancelled {
            report.phase = "cancelled"
            report.observedAt = Date()
            progress(report)
            return report
        }
        let known = report.results.compactMap { result -> Date? in
            guard let seconds = result.candidateSeconds, seconds >= 0, seconds <= 12 * 3600 - 90,
                  let captured = result.capturedAt else { return nil }
            return captured.addingTimeInterval(TimeInterval(seconds + 90))
        }
        guard let candidateDeadline = known.max() else {
            report.phase = "no_bounded_candidate"
            report.observedAt = Date()
            progress(report)
            return report
        }
        let deadline = smoke ? Date().addingTimeInterval(2) : candidateDeadline
        for index in report.results.indices where report.results[index].state == "prefix_saved" {
            report.results[index].waitUntil = deadline
            report.results[index].state = "waiting"
        }
        report.phase = smoke ? "waiting_smoke" : "waiting"
        report.observedAt = Date()
        progress(report)
        do {
            try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            try Task.checkCancellation()
            for provider in Provider.allCases {
                guard let context = contexts[provider],
                      let index = report.results.firstIndex(where: { $0.provider == provider.rawValue }) else { continue }
                report.phase = "probing_\(provider.rawValue)"
                report.observedAt = Date()
                progress(report)
                do {
                    guard try naturalExpiryAccountMatches(context.request.context) else {
                        report.results[index].state = "account_changed"
                        continue
                    }
                    let old = try await context.source.oldLink()
                    let status = try await Self.probeOldLink(old, configuration: context.network)
                    report.results[index].oldHTTPStatus = status
                    if smoke {
                        report.results[index].state = "smoke_probe_\(status)"
                        continue
                    }
                    guard [403, 404, 410, 416].contains(status) else {
                        report.results[index].state = [200, 206].contains(status) ? "not_expired" : "old_probe_inconclusive"
                        continue
                    }
                    report.results[index].state = "old_link_rejected"
                    progress(report)
                    try await completeNaturalExpiry(context, result: &report.results[index])
                } catch is CancellationError { throw CancellationError() }
                catch let error as RangeVerificationFailure { report.results[index].state = error.status }
                catch { report.results[index].state = "resume_verification_failed" }
                report.observedAt = Date()
                progress(report)
            }
            report.phase = smoke ? "finished_smoke" : "finished"
        } catch {
            report.phase = "cancelled"
        }
        report.observedAt = Date()
        progress(report)
        return report
    }

    /// 根目录与最多八个目录；优先应用目录，只选有限大小的真实账号文件。
    private func naturalExpirySample(_ disk: any Netdisk) async throws -> RemoteEntry? {
        func candidate(_ entries: [RemoteEntry]) -> RemoteEntry? {
            entries.filter { !$0.isDirectory && $0.size > NaturalExpiryContext.prefix && $0.size <= 64 << 20 }
                .max { $0.size < $1.size }
        }
        let root = try await disk.listDirectory(nil)
        if let file = candidate(root) { return file }
        let own = settings.transferFolder(for: disk.account.provider).split(separator: "/").last.map(String.init)
        let directories = root.filter(\.isDirectory)
        var pending = Array((directories.filter { $0.name == own } + directories.filter { $0.name != own }).prefix(8))
        var visited = Set<RemoteReference>()
        var cursor = 0
        while cursor < pending.count, visited.count < 8 {
            try Task.checkCancellation()
            let directory = pending[cursor]
            cursor += 1
            guard visited.insert(directory.reference).inserted else { continue }
            let entries = try await disk.listDirectory(directory.reference)
            if let file = candidate(entries) { return file }
            pending.append(contentsOf: entries.filter(\.isDirectory).prefix(8))
        }
        return nil
    }

    /// 只取响应头即取消，服务器忽略 Range 也不会完整读取响应体；沿用跨主机不转发 Cookie 的规则。
    private static func probeOldLink(_ link: ResolvedURL, configuration: URLSessionConfiguration) async throws -> Int {
        var request = URLRequest(url: link.url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.allHTTPHeaderFields = link.headers
        request.setValue("bytes=65536-65536", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: NaturalExpiryRedirect(request))
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw RangeVerificationFailure("invalid_probe_response") }
        return http.statusCode
    }

    /// 正式引擎首返旧链接、随后正式重新解析；恢复同一记录，完整文件再与新解析同身份样本核对。
    private func completeNaturalExpiry(_ context: NaturalExpiryContext,
                                      result: inout NaturalExpiryReport.Result) async throws {
        await context.source.prepareReplay()
        let prefix = try Self.naturalPartialData(context)
        guard prefix.count == NaturalExpiryContext.prefix,
              SHA256.hash(data: prefix).map({ String(format: "%02x", $0) }).joined() == result.prefixSHA256 else {
            throw RangeVerificationFailure("partial_changed_during_wait")
        }
        let engine = context.engine()
        do {
            let events = engine.events()
            let restored = try await engine.restore()
            guard let snapshot = restored.first(where: { $0.id == context.request.id }), snapshot.state == .paused,
                  snapshot.receivedBytes == NaturalExpiryContext.prefix else {
                throw RangeVerificationFailure("restored_checkpoint_mismatch")
            }
            await engine.resume(id: context.request.id)
            let completed = try await Self.awaitNaturalCompletion(engine, events: events, id: context.request.id)
            let counts = await context.source.counts()
            result.oldReplayCount = counts.replays
            result.freshResolveCount = counts.refreshes
            guard counts.replays == 1, counts.refreshes >= 1 else { throw RangeVerificationFailure("refresh_not_observed") }
            let handle = try FileHandle(forReadingFrom: completed)
            let actualPrefix = try handle.read(upToCount: Int(NaturalExpiryContext.prefix))
            try handle.close()
            guard actualPrefix == prefix else { throw RangeVerificationFailure("prefix_changed") }
            result.sha256 = try Self.naturalFileHash(completed, expectedSize: context.request.expectedSize!)
            result.receivedBytes = context.request.expectedSize
            await engine.shutdown()
            if context.request.expectedMD5 == nil {
                var baseline = context.request
                baseline.id = UUID().uuidString
                baseline.destination = context.directory.appendingPathComponent("fresh-checksum.bin")
                let checker = context.engine(stateFolder: "ChecksumDownloads")
                do {
                    let events = checker.events()
                    try await checker.enqueue(baseline)
                    let file = try await Self.awaitNaturalCompletion(checker, events: events, id: baseline.id)
                    result.sourceSHA256 = try Self.naturalFileHash(file, expectedSize: baseline.expectedSize!)
                    await checker.shutdown()
                } catch { await checker.shutdown(); throw error }
                guard result.sourceSHA256 == result.sha256 else { throw RangeVerificationFailure("fresh_content_mismatch") }
            }
            result.state = "verified"
        } catch { await engine.shutdown(); throw error }
    }

    /// 立即验证正式引擎实际写盘的暂停和位移，不能只靠内存状态等待数小时。
    private static func naturalSavedOffset(_ context: NaturalExpiryContext) throws -> Int64 {
        struct Checkpoint: Decodable {
            struct Segment: Decodable { let received: Int64 }
            let segments: [Segment]
            let isPaused: Bool
        }
        let name = context.request.id.utf8.map { String(format: "%02x", $0) }.joined() + ".json"
        let file = context.directory.appendingPathComponent("Downloads").appendingPathComponent(name)
        let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: file))
        guard checkpoint.isPaused else { throw RangeVerificationFailure("prefix_not_persisted") }
        return checkpoint.segments.reduce(0) { $0 + $1.received }
    }

    /// 专用目录只有本次单个下载；只读取其有限分片，不复制临时路径算法。
    private static func naturalPartialData(_ context: NaturalExpiryContext) throws -> Data {
        let partials = try FileManager.default.contentsOfDirectory(at: context.directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "ferrydownload" }
        guard partials.count == 1, let partial = partials.first else { throw RangeVerificationFailure("partial_missing") }
        let handle = try FileHandle(forReadingFrom: partial)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: Int(NaturalExpiryContext.prefix) + 1) ?? Data()
        return bytes
    }

    /// 事件驱动等待完成；单次恢复或校验下载最多二十分钟，取消后由调用方关闭引擎。
    private static func awaitNaturalCompletion(_ engine: DownloadEngine, events: AsyncStream<DownloadEvent>, id: String) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                for await event in events {
                    try Task.checkCancellation()
                    guard case .stateChanged(let snapshot) = event, snapshot.id == id else { continue }
                    switch snapshot.state {
                    case .completed(let url): return url
                    case .failed: throw RangeVerificationFailure("download_failed")
                    default: break
                    }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20 * 60))
                throw RangeVerificationFailure("download_deadline")
            }
            defer { group.cancelAll() }
            guard let completed = try await group.next() else { throw CancellationError() }
            return completed
        }
    }

    /// 有界分块读取，不把完整文件载入内存；大小不符时不能报告成功。
    private static func naturalFileHash(_ url: URL, expectedSize: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var size: Int64 = 0
        while let bytes = try handle.read(upToCount: 1 << 20), !bytes.isEmpty {
            try Task.checkCancellation()
            size += Int64(bytes.count)
            guard size <= expectedSize else { throw RangeVerificationFailure("file_size_mismatch") }
            hash.update(data: bytes)
        }
        guard size == expectedSize else { throw RangeVerificationFailure("file_size_mismatch") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 探测只使用正式链接头；重定向时 Cookie 不传播到其他主机。
nonisolated private final class NaturalExpiryRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    private let headers: [String: String]
    private let host: String?
    init(_ request: URLRequest) { headers = request.allHTTPHeaderFields ?? [:]; host = request.url?.host()?.lowercased() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { return completionHandler(nil) }
        var request = request
        let sameHost = request.url?.host()?.lowercased() == host
        if !sameHost { request.setValue(nil, forHTTPHeaderField: "Cookie") }
        for (key, value) in headers where request.value(forHTTPHeaderField: key) == nil {
            if !sameHost, key.caseInsensitiveCompare("Cookie") == .orderedSame { continue }
            request.setValue(value, forHTTPHeaderField: key)
        }
        completionHandler(request)
    }
}
#endif
