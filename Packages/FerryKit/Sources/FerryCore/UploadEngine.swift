import Foundation
import Darwin
import DownloadKit

public enum UploadEngineError: Error, LocalizedError, Sendable {
    case invalidRetryConfiguration
    case invalidPartConcurrency
    public var errorDescription: String? {
        switch self {
        case .invalidRetryConfiguration: "分片额外重试次数必须为 0～5，等待时间必须为 0～10 秒"
        case .invalidPartConcurrency: "每个上传文件的并发分片数必须为 1～4"
        }
    }
}

/// 只统计服务端已确认且已持久化的逻辑字节；重复执行和分片重试不会重复累加。
public struct UploadEngineProgress: Sendable, Equatable {
    public let confirmedBytes: Int64
    public let totalBytes: Int64
    public let confirmedPartCount: Int
    public let pendingPartCount: Int
}

/// 单文件有界并发执行器。准备、分块重算、合并和回读由上层阶段调度负责。
/// 每路最多保留一个分片缓冲，回执由父任务串行保存；不持有完整文件副本。
public struct UploadEngine: Sendable {
    private let destination: any UploadDestination
    private let budget: TransferBudget
    private let maximumPartRetries: Int
    private let partRetryDelay: Duration
    private let maximumConcurrentParts: Int

    public init(destination: any UploadDestination, budget: TransferBudget, maximumPartRetries: Int = 2,
                partRetryDelay: Duration = .milliseconds(300), maximumConcurrentParts: Int = 1) throws {
        guard (0...5).contains(maximumPartRetries), (.zero ... .seconds(10)).contains(partRetryDelay) else {
            throw UploadEngineError.invalidRetryConfiguration
        }
        guard (1...4).contains(maximumConcurrentParts) else { throw UploadEngineError.invalidPartConcurrency }
        self.destination = destination; self.budget = budget
        self.maximumPartRetries = maximumPartRetries
        self.partRetryDelay = partRetryDelay
        self.maximumConcurrentParts = maximumConcurrentParts
    }

    /// 只发送本会话待发且没有持久回执的分片；每个确认回执必须先成功保存才推进。
    /// 调用方负责本地 URL 的 security-scope 授权整个执行期，取消或任何保存失败均向上抛出。
    public func upload(
        localURL: URL,
        prepared: PreparedUpload,
        receipts: [UploadPartReceipt],
        onReceipt: @Sendable (UploadPartReceipt) async throws -> Void,
        onProgress: (@Sendable (UploadEngineProgress) async throws -> Void)? = nil
    ) async throws -> [UploadPartReceipt] {
        try Task.checkCancellation()
        try prepared.validate()
        guard prepared.account == destination.account else { throw UploadDestinationError.otherAccount }
        guard prepared.isReadyForTransfer else { throw UploadDestinationError.invalidPreparation }
        guard !prepared.requiresRechunking else { throw UploadDestinationError.requiresChunkSize(prepared.partSize) }
        let pending = Set(prepared.pendingParts)
        var confirmed: [Int: UploadPartReceipt] = [:]
        var pendingBytes: Int64 = 0
        for index in prepared.pendingParts { pendingBytes += length(of: index, prepared: prepared) }
        var confirmedBytes = prepared.source.identity.size - pendingBytes
        for receipt in receipts {
            guard pending.contains(receipt.index), confirmed[receipt.index] == nil else {
                throw UploadDestinationError.invalidReceipt
            }
            try check(receipt, index: receipt.index, prepared: prepared)
            confirmed[receipt.index] = receipt
            confirmedBytes += receipt.length
        }
        if let onProgress {
            try await onProgress(.init(confirmedBytes: confirmedBytes, totalBytes: prepared.source.identity.size,
                confirmedPartCount: confirmed.count, pendingPartCount: pending.count))
        }
        let missing = prepared.pendingParts.filter { confirmed[$0] == nil }.sorted()
        // 秒传或所有分片都有回执时不再要求本地源存在，下一阶段仍须核对远端和完整内容。
        guard !missing.isEmpty else { return confirmed.values.sorted { $0.index < $1.index } }
        let descriptor = try open(localURL)
        defer { Darwin.close(descriptor) }
        let sourceIdentity = prepared.source.identity
        try verify(descriptor: descriptor, url: localURL, expected: sourceIdentity)
        let failure = await withTaskGroup(of: Result<UploadPartReceipt, any Error>.self) { group in
            var next = 0
            var firstError: (any Error)?
            // 初始窗口和后续补位都只分配任务；额度等待阶段不占分片内容缓冲。
            for _ in 0..<min(maximumConcurrentParts, missing.count) {
                let index = missing[next]; next += 1
                group.addTask { await partResult(index: index, descriptor: descriptor, url: localURL, prepared: prepared) }
            }
            while let result = await group.next() {
                switch result {
                case .success(let receipt):
                    do {
                        // 即使其他分片失败或用户取消，也优先保存已经取得的成功回执。
                        // 只能由父任务逐个调用，避免并发读改写文件聚合和回执数组。
                        try await onReceipt(receipt)
                        confirmed[receipt.index] = receipt
                        confirmedBytes += receipt.length
                        if firstError == nil, let onProgress {
                            try await onProgress(.init(confirmedBytes: confirmedBytes, totalBytes: prepared.source.identity.size,
                                confirmedPartCount: confirmed.count, pendingPartCount: pending.count))
                        }
                        try verify(descriptor: descriptor, url: localURL, expected: sourceIdentity)
                    } catch { if firstError == nil { firstError = error } }
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
                if Task.isCancelled, firstError == nil { firstError = CancellationError() }
                if firstError != nil { group.cancelAll() }
                else if next < missing.count {
                    let index = missing[next]; next += 1
                    group.addTask { await partResult(index: index, descriptor: descriptor, url: localURL, prepared: prepared) }
                }
            }
            // Result 任务组收齐所有在途结果再抛错；描述符直到子任务全部退出后才关闭。
            return firstError
        }
        if let failure { throw failure }
        try Task.checkCancellation()
        return confirmed.values.sorted { $0.index < $1.index }
    }

    /// 每路先领取速率额度，再以线程安全 pread 读取自己的分片；只返回小回执，不保留内容缓冲。
    private func partResult(index: Int, descriptor: Int32, url: URL, prepared: PreparedUpload) async -> Result<UploadPartReceipt, any Error> {
        do {
            try Task.checkCancellation()
            let count = Int(length(of: index, prepared: prepared))
            try await budget.consume(count, direction: .upload)
            try verify(descriptor: descriptor, url: url, expected: prepared.source.identity)
            let bytes = try read(descriptor: descriptor, offset: Int64(index) * prepared.partSize, count: count, url: url)
            try verify(descriptor: descriptor, url: url, expected: prepared.source.identity)
            let receipt = try await send(bytes, index: index, expectedSHA256: sha256(of: index, prepared: prepared),
                                         prepared: prepared, descriptor: descriptor, url: url)
            try check(receipt, index: index, prepared: prepared)
            return .success(receipt)
        } catch { return .failure(error) }
    }

    /// 首次额度在读取缓冲前领取；重试重新计入发送流量，始终发送同一份已核对字节。
    private func send(_ bytes: Data, index: Int, expectedSHA256: String, prepared: PreparedUpload,
                      descriptor: Int32, url: URL) async throws -> UploadPartReceipt {
        for attempt in 0...maximumPartRetries {
            try Task.checkCancellation()
            try verify(descriptor: descriptor, url: url, expected: prepared.source.identity)
            if attempt > 0 {
                try await budget.consume(bytes.count, direction: .upload)
                try verify(descriptor: descriptor, url: url, expected: prepared.source.identity)
            }
            do {
                return try await budget.withPermit {
                    try Task.checkCancellation()
                    try verify(descriptor: descriptor, url: url, expected: prepared.source.identity)
                    return try await destination.uploadPart(bytes, index: index, expectedSHA256: expectedSHA256, prepared: prepared)
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                guard attempt < maximumPartRetries, destination.shouldRetryPart(after: error) else { throw error }
                // withPermit 已释放连接；等待期间取消立即退出，也不产生后续逻辑进度。
                if partRetryDelay > .zero { try await Task.sleep(for: partRetryDelay) }
                try verify(descriptor: descriptor, url: url, expected: prepared.source.identity)
            }
        }
        throw UploadDestinationError.invalidReceipt
    }

    /// 恢复回执必须属于当前待发片及原始源版本，非空服务端回执由对应策略在合并时解析核对。
    private func check(_ receipt: UploadPartReceipt, index: Int, prepared: PreparedUpload) throws {
        guard receipt.index == index, receipt.offset == Int64(index) * prepared.partSize,
              receipt.length == length(of: index, prepared: prepared),
              receipt.sourceSHA256 == sha256(of: index, prepared: prepared),
              !receipt.serverReceipt.isEmpty else { throw UploadDestinationError.invalidReceipt }
    }

    private func length(of index: Int, prepared: PreparedUpload) -> Int64 {
        min(prepared.partSize, prepared.source.identity.size - Int64(index) * prepared.partSize)
    }

    private func sha256(of index: Int, prepared: PreparedUpload) -> String {
        prepared.source.identity.size == 0
            ? "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            : prepared.source.chunks[index].sha256
    }

    /// 不跟随最终路径符号链接；非阻塞打开防止竞争替换成 FIFO 时挂起工作线程。
    private func open(_ url: URL) throws -> Int32 {
        guard url.isFileURL else { throw UploadSourceError.nonFileURL }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw UploadSourceError.symbolicLink(url.path) }
            throw UploadSourceError.inaccessible(url.path, code: errno)
        }
        return descriptor
    }

    /// 路径与打开的描述符同时检查，拒绝替换路径、截断、原地改写和文件类型变化。
    private func verify(descriptor: Int32, url: URL, expected: UploadSourceIdentity) throws {
        guard try UploadSource.identity(of: url) == expected else { throw UploadSourceError.changed(url.path) }
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw UploadSourceError.inaccessible(url.path, code: errno) }
        guard value.st_mode & S_IFMT == S_IFREG,
              UInt64(bitPattern: Int64(value.st_dev)) == expected.device,
              UInt64(value.st_ino) == expected.inode, value.st_size == expected.size,
              matches(seconds: Int64(value.st_mtimespec.tv_sec), nanos: Int64(value.st_mtimespec.tv_nsec), total: expected.modifiedNanoseconds),
              matches(seconds: Int64(value.st_ctimespec.tv_sec), nanos: Int64(value.st_ctimespec.tv_nsec), total: expected.changedNanoseconds) else {
            throw UploadSourceError.changed(url.path)
        }
    }

    private func matches(seconds: Int64, nanos: Int64, total: Int64) -> Bool {
        let (secondsPart, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (value, sumOverflow) = secondsPart.addingReportingOverflow(nanos)
        return !overflow && !sumOverflow && value == total
    }

    /// 在唯一分片缓冲中原地分段读取，短读继续，EOF 或取消明确结束，不分配额外内容副本。
    private func read(descriptor: Int32, offset: Int64, count: Int, url: URL) throws -> Data {
        var bytes = Data(count: count)
        try bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var position = 0
            while position < count {
                try Task.checkCancellation()
                let amount = min(1_048_576, count - position)
                let received = pread(descriptor, buffer.baseAddress!.advanced(by: position), amount, offset + Int64(position))
                if received < 0 {
                    if errno == EINTR { continue }
                    throw UploadSourceError.inaccessible(url.path, code: errno)
                }
                guard received > 0 else { throw UploadSourceError.changed(url.path) }
                position += received
            }
        }
        return bytes
    }
}
