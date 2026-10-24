import Foundation
import os

/// 原始文件的有界范围读取。响应头先验证，再接收最多一个范围；不会把服务器忽略 Range 的整文件读入内存。
/// session 由调用方持有和配置代理／超时，读取器不 invalidate 共享会话，也不负责刷新失效地址。
public struct RangeReader: Sendable {
    public static let maximumRangeLength = 1 << 20
    public static let defaultRangeLength = 256 << 10

    private let session: URLSession
    private let budget: TransferBudget?
    public let rangeLengthLimit: Int

    public init(session: URLSession, budget: TransferBudget? = nil, rangeLengthLimit: Int = Self.defaultRangeLength) throws {
        guard rangeLengthLimit > 0, rangeLengthLimit <= Self.maximumRangeLength else {
            throw DownloadFailure.invalidResponse("回读范围上限必须在 1 字节到 1 MiB 之间")
        }
        self.session = session; self.budget = budget; self.rangeLengthLimit = rangeLengthLimit
    }

    /// 读取 [lowerBound, upperBound)，返回值长度严格等于请求范围。
    /// 下载速率额度在请求前申请；每个在途请求的网络突发最多 rangeLengthLimit，调用方限制同时回读数。
    public func read(_ range: Range<Int64>, totalSize: Int64, from resolved: ResolvedURL) async throws -> Data {
        guard totalSize > 0, range.lowerBound >= 0, range.upperBound > range.lowerBound,
              range.upperBound <= totalSize, range.count <= rangeLengthLimit else {
            throw DownloadFailure.invalidResponse("回读范围超出文件或缓冲上限")
        }
        let length = Int(range.upperBound - range.lowerBound)
        try validateURL(resolved.url)
        if let budget {
            try await budget.consume(length, direction: .download)
            return try await budget.withPermit { try await perform(range: range, totalSize: totalSize, resolved: resolved) }
        }
        return try await perform(range: range, totalSize: totalSize, resolved: resolved)
    }

    /// 零字节对象使用普通 GET；必须收到 200 和零长度原始内容，不生成非法空 Range。
    public func validateEmpty(from resolved: ResolvedURL) async throws {
        try validateURL(resolved.url)
        if let budget {
            try await budget.withPermit { _ = try await perform(range: nil, totalSize: 0, resolved: resolved) }
        } else {
            _ = try await perform(range: nil, totalSize: 0, resolved: resolved)
        }
    }

    private func validateURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil else {
            throw DownloadFailure.invalidResponse("回读地址必须是 HTTP 或 HTTPS")
        }
    }

    private func perform(range: Range<Int64>?, totalSize: Int64, resolved: ResolvedURL) async throws -> Data {
        try Task.checkCancellation()
        let length = range.map { Int($0.upperBound - $0.lowerBound) } ?? 0
        let body = RangeBody(limit: length)
        var request = URLRequest(url: resolved.url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: session.configuration.timeoutIntervalForRequest)
        for (key, value) in resolved.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(range.map { "bytes=\($0.lowerBound)-\($0.upperBound - 1)" }, forHTTPHeaderField: "Range")
        do {
            try await DataTaskRunner.run(request, session: session, onResponse: { response in
                try Self.checkResponse(response, range: range, totalSize: totalSize, length: length)
                return true
            }, onData: { data in try body.append(data) })
            try Task.checkCancellation()
            return try body.complete()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let failure = error as? DownloadFailure { throw failure }
            if let failure = error as? FetchError { throw failure.failure }
            throw error
        }
    }

    private static func checkResponse(_ response: HTTPURLResponse, range: Range<Int64>?, totalSize: Int64, length: Int) throws {
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard encoding == nil || encoding == "identity" else {
            throw DownloadFailure.invalidResponse("回读响应经过内容编码，无法核对原始字节")
        }
        if let range {
            guard response.statusCode == 206 else {
                throw DownloadFailure.invalidResponse("服务器忽略回读 Range，状态码 \(response.statusCode)")
            }
            guard let header = response.value(forHTTPHeaderField: "Content-Range"), let actual = ContentRange(header),
                  actual.first == range.lowerBound, actual.last == range.upperBound - 1, actual.total == totalSize else {
                throw DownloadFailure.invalidResponse("回读 Content-Range 与预期范围或文件大小不一致")
            }
        } else {
            guard response.statusCode == 200, response.value(forHTTPHeaderField: "Content-Range") == nil else {
                throw DownloadFailure.invalidResponse("空文件回读响应无效")
            }
        }
        if let header = response.value(forHTTPHeaderField: "Content-Length") {
            guard let declared = Int64(header), declared == Int64(length) else {
                throw DownloadFailure.invalidResponse("回读 Content-Length 与请求范围不一致")
            }
        }
    }
}

/// delegate 可能在不同队列回调；边界检查和追加必须在同一个锁内。
private final class RangeBody: Sendable {
    private let limit: Int
    private let bytes = OSAllocatedUnfairLock(initialState: Data())
    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) throws {
        try bytes.withLock { data in
            guard chunk.count <= limit - data.count else {
                throw DownloadFailure.invalidResponse("回读响应体超出请求范围")
            }
            data.append(chunk)
        }
    }

    func complete() throws -> Data {
        try bytes.withLock { data in
            guard data.count == limit else { throw DownloadFailure.invalidResponse("回读响应体长度不足") }
            return data
        }
    }
}
