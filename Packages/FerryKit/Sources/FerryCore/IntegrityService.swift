import Foundation
import CryptoKit
import DownloadKit

/// 对精确远端对象顺序回读并计算完整 SHA-256；仅持有一个范围缓冲，不保存完整文件副本。
/// 账号／对象版本由调用方在 resolve 中核对；服务不管理登录、任务或持久化。
public struct IntegrityService: Sendable {
    private let reader: RangeReader
    private let maximumRetries: Int
    private let retryDelay: Duration

    /// 最多重试十次，避免持久错误形成无界循环；等待可取消，且不占连接许可。
    public init(reader: RangeReader, maximumRetries: Int = 3, retryDelay: Duration = .milliseconds(250)) throws {
        guard (0...10).contains(maximumRetries), retryDelay >= .zero else {
            throw UploadRecordError.invalid("校验重试次数必须为 0～10，等待时间不能为负数")
        }
        self.reader = reader; self.maximumRetries = maximumRetries; self.retryDelay = retryDelay
    }

    /// 只有整个对象回读完才返回 verified／mismatch；网络或权限错误直接抛出，不能冒充内容不一致。
    /// 每段完整校验成功后才推进摘要。取消后重新调用从首字节重算，进度不充当可恢复哈希状态。
    public func verify(account: AccountKey, reference: RemoteReference, expectedSHA256: String, size: Int64,
                       remoteVersion: String? = nil, uploadFileID: UUID? = nil,
                       origin: IntegrityOrigin = .localOriginal,
                       resolve: @Sendable () async throws -> ResolvedURL,
                       onProgress: (@Sendable (_ verifiedBytes: Int64, _ totalBytes: Int64) async throws -> Void)? = nil) async throws -> IntegrityRecord {
        let expectation = try IntegrityExpectation(algorithm: .sha256, digest: expectedSHA256, origin: origin,
                                                   size: size, reference: reference, remoteVersion: remoteVersion)
        var record = IntegrityRecord(account: account, reference: reference, remoteVersion: remoteVersion,
                                     expectation: expectation, uploadFileID: uploadFileID)
        try record.validate()
        try Task.checkCancellation()
        var location = try await resolve()
        var hasher = SHA256()
        var offset: Int64 = 0
        if size == 0 {
            _ = try await fetch(nil, size: size, location: &location, resolve: resolve)
            try await onProgress?(0, 0)
        }
        while offset < size {
            try Task.checkCancellation()
            let length = min(Int64(reader.rangeLengthLimit), size - offset)
            let data = try await fetch(offset..<(offset + length), size: size, location: &location, resolve: resolve)
            hasher.update(data: data)
            offset += length
            try await onProgress?(offset, size)
        }
        try Task.checkCancellation()
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        record.actualDigest = actual
        record.status = actual == expectation.digest ? .verified : .mismatch
        record.verifiedAt = .now
        if record.status == .mismatch { record.error = "云端文件 SHA-256 与原始内容基准不一致" }
        try record.validate()
        return record
    }

    /// 失败范围丢弃后整体重读，避免半段与重试完整段重复进入 SHA-256。
    private func fetch(_ range: Range<Int64>?, size: Int64, location: inout ResolvedURL,
                       resolve: @Sendable () async throws -> ResolvedURL) async throws -> Data {
        for attempt in 0...maximumRetries {
            try Task.checkCancellation()
            do {
                if let range { return try await reader.read(range, totalSize: size, from: location) }
                try await reader.validateEmpty(from: location)
                return Data()
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                guard attempt < maximumRetries, let action = recovery(for: error) else { throw error }
                if retryDelay > .zero { try await Task.sleep(for: retryDelay) }
                if action { location = try await resolve() }
            }
        }
        preconditionFailure("有限回读重试必须返回或抛出")
    }

    /// true 刷新短期地址；false 复用地址重试。其他业务／文件错误交回上层处理。
    private func recovery(for error: any Error) -> Bool? {
        guard let failure = error as? DownloadFailure else { return nil }
        switch failure {
        case .network(let code):
            return code == .cancelled ? nil : false
        case .httpStatus(let status, _):
            if [401, 403, 404, 410, 416].contains(status) { return true }
            if status == 429 || status == 509 || (500...599).contains(status) { return false }
            return nil
        case .invalidResponse: return true
        case .resolveFailed, .fileSystem: return nil
        }
    }
}
