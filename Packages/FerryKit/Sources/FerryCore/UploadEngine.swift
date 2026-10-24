import Foundation
import Darwin
import DownloadKit

/// 只统计服务端已确认且已持久化的逻辑字节；重复执行和分片重试不会重复累加。
public struct UploadEngineProgress: Sendable, Equatable {
    public let confirmedBytes: Int64
    public let totalBytes: Int64
    public let confirmedPartCount: Int
    public let pendingPartCount: Int
}

/// 单文件顺序执行器。准备、分块重算、合并和回读由上层阶段调度负责。
/// 仅保留一个服务端分片的内容缓冲；不持有计时任务、队列或完整文件副本。
public struct UploadEngine: Sendable {
    private let destination: any UploadDestination
    private let budget: TransferBudget

    public init(destination: any UploadDestination, budget: TransferBudget) {
        self.destination = destination; self.budget = budget
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
        for index in missing {
            try Task.checkCancellation()
            let count = Int(length(of: index, prepared: prepared))
            // 先等速率额度再占内容缓冲，等待限速期间不占连接许可。
            try await budget.consume(count, direction: .upload)
            try verify(descriptor: descriptor, url: localURL, expected: sourceIdentity)
            let bytes = try read(descriptor: descriptor, offset: Int64(index) * prepared.partSize,
                                 count: count, url: localURL)
            try verify(descriptor: descriptor, url: localURL, expected: sourceIdentity)
            let expectedSHA256 = sha256(of: index, prepared: prepared)
            let receipt = try await budget.withPermit {
                try Task.checkCancellation()
                // 等待连接期间路径可能被替换；核对后发送已读出的同一份字节。
                try verify(descriptor: descriptor, url: localURL, expected: sourceIdentity)
                return try await destination.uploadPart(bytes, index: index, expectedSHA256: expectedSHA256, prepared: prepared)
            }
            try check(receipt, index: index, prepared: prepared)
            // 收到确认后优先保存，不在此边界先检查取消而丢掉已确认回执。
            try await onReceipt(receipt)
            confirmed[index] = receipt
            confirmedBytes += receipt.length
            if let onProgress {
                try await onProgress(.init(confirmedBytes: confirmedBytes, totalBytes: prepared.source.identity.size,
                    confirmedPartCount: confirmed.count, pendingPartCount: pending.count))
            }
            try Task.checkCancellation()
            try verify(descriptor: descriptor, url: localURL, expected: sourceIdentity)
        }
        return confirmed.values.sorted { $0.index < $1.index }
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
