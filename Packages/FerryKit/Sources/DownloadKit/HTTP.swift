import Foundation
import os

/// 一次请求或一次文件操作失败的原因。重试策略按它决定怎样处理。
enum FetchError: Error {
    case network(URLError.Code)
    case http(status: Int, body: String)
    case invalidResponse(String)
    /// 服务器对 Range 请求返回了整个文件。
    case rangeIgnored
    case streamBufferExceeded
    /// `permanent` 为 true 时，下载源抛出的是 `PermanentDownloadSourceError`，重试也不会成功。
    case resolve(String, permanent: Bool)
    case disk(String)

    init(_ error: any Error) {
        switch error {
        case let error as FetchError: self = error
        case let error as URLError: self = .network(error.code)
        default: self = .network(.unknown)
        }
    }

    var isRetryable: Bool {
        switch self {
        case .disk, .rangeIgnored, .streamBufferExceeded: false
        case .resolve(_, let permanent): !permanent
        default: true
        }
    }

    /// 这些情况多半是下载链接过期或失效，要重新获取链接。
    var invalidatesLink: Bool {
        switch self {
        case .http(let status, _): [403, 404, 410, 416].contains(status)
        case .invalidResponse: true
        case .network(let code): Self.linkNetworkErrors.contains(code)
        default: false
        }
    }

    /// 证书或连接问题多半出在这个下载链接的主机上（例如证书无效的 `nb.cache` 主机）。
    /// 重新获取链接可能换到另一个主机。
    private static let linkNetworkErrors: Set<URLError.Code> = [
        .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
        .serverCertificateHasUnknownRoot, .clientCertificateRejected, .secureConnectionFailed,
        .cannotConnectToHost, .cannotFindHost,
    ]

    var isThrottled: Bool {
        if case .http(let status, _) = self { [429, 509].contains(status) } else { false }
    }

    var failure: DownloadFailure {
        switch self {
        case .network(let code): .network(code)
        case .http(let status, let body): .httpStatus(status, message: body)
        case .invalidResponse(let reason): .invalidResponse(reason)
        case .rangeIgnored: .invalidResponse("server ignored the Range header")
        case .streamBufferExceeded: .invalidResponse("下载接收缓存超过 8 MiB，已停止请求以保持内存有界")
        case .resolve(let reason, _): .resolveFailed(reason)
        case .disk(let reason): .fileSystem(reason)
        }
    }
}

/// `Content-Range: bytes first-last/total`。
struct ContentRange: Equatable {
    var first: Int64
    var last: Int64
    /// 服务器写 `*` 时为 nil。
    var total: Int64?

    init?(_ header: String) {
        let parts = header.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = parts[1].split(separator: "/", maxSplits: 1)
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
        guard rangeAndTotal.count == 2, bounds.count == 2,
              let first = Int64(bounds[0]), let last = Int64(bounds[1]), first <= last
        else { return nil }
        self.first = first
        self.last = last
        if rangeAndTotal[1] == "*" {
            total = nil
        } else if let total = Int64(rangeAndTotal[1]), total > last {
            self.total = total
        } else {
            return nil
        }
    }
}

/// 运行一个 data task，响应体按数据块交给 `onData`（不逐字节迭代）。
///
/// 非 2xx 响应不交给调用方，而是读取响应体的开头作为错误信息，抛出 `FetchError.http`。
final class DataTaskRunner: NSObject, URLSessionDataDelegate, Sendable {
    /// 2xx 响应到达时调用。返回 false 表示只要响应头，不接收响应体。
    typealias ResponseHandler = @Sendable (HTTPURLResponse) throws -> Bool
    typealias DataHandler = @Sendable (Data) throws -> Void

    private static let errorBodyLimit = 4096
    private static let streamBufferLimit = 8 * 1024 * 1024

    private struct State {
        var continuation: CheckedContinuation<HTTPURLResponse, any Error>?
        var response: HTTPURLResponse?
        var error: (any Error)?
        var errorBody: Data?
        var stoppedAfterResponse = false
        var completed = false
        var completionError: (any Error)?
        var buffered: [Data] = []
        var bufferedBytes = 0
        var suspended = false
        var consumer: Task<Void, Never>?
    }

    private let headers: [String: String]
    private let host: String?
    private let onResponse: ResponseHandler
    private let onData: DataHandler
    private let streamByteBudget: TransferBudget?
    private let state = OSAllocatedUnfairLock(initialState: State())

    private init(request: URLRequest, streamByteBudget: TransferBudget?, onResponse: @escaping ResponseHandler, onData: @escaping DataHandler) {
        headers = request.allHTTPHeaderFields ?? [:]
        host = request.url?.host()?.lowercased()
        self.onResponse = onResponse
        self.onData = onData
        self.streamByteBudget = streamByteBudget
    }

    @discardableResult
    static func run(
        _ request: URLRequest,
        session: URLSession,
        transferBudget: TransferBudget? = nil,
        streamByteBudget: TransferBudget? = nil,
        onResponse: @escaping ResponseHandler = { _ in true },
        onData: @escaping DataHandler = { _ in }
    ) async throws -> HTTPURLResponse {
        if let transferBudget {
            return try await transferBudget.withPermit {
                try await runRequest(request, session: session, streamByteBudget: streamByteBudget, onResponse: onResponse, onData: onData)
            }
        }
        return try await runRequest(request, session: session, streamByteBudget: streamByteBudget, onResponse: onResponse, onData: onData)
    }

    /// 每个真实 HTTP 请求持有一份连接许可；取消及错误均在请求终止后归还。
    private static func runRequest(
        _ request: URLRequest,
        session: URLSession,
        streamByteBudget: TransferBudget?,
        onResponse: @escaping ResponseHandler,
        onData: @escaping DataHandler
    ) async throws -> HTTPURLResponse {
        try Task.checkCancellation()
        let runner = DataTaskRunner(request: request, streamByteBudget: streamByteBudget, onResponse: onResponse, onData: onData)
        let activeSession: URLSession
        if streamByteBudget != nil {
            let configuration = session.configuration
            // 实测暂停仍会耗尽 resource 总时限；慢流只由连接／无数据超时与用户取消约束。
            configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
            activeSession = URLSession(configuration: configuration, delegate: session.delegate, delegateQueue: nil)
        } else { activeSession = session }
        defer { if streamByteBudget != nil { activeSession.invalidateAndCancel() } }
        let task = activeSession.dataTask(with: request)
        task.delegate = runner
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                runner.state.withLock { $0.continuation = continuation }
                // 取消可能先于 continuation 注册，保留的完成结果仍须交还调用方。
                runner.resumeIfCompleted()
                task.resume()
            }
        } onCancel: {
            runner.cancelConsumer()
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // 重定向时 URLSession 会丢掉部分自定义请求头（例如 Range），这里补上。
        // Cookie 只发给原始请求的主机：重定向到其他主机时不带 Cookie，不把登录信息交给第三方主机。
        var request = request
        let sameHost = request.url?.host()?.lowercased() == host
        if !sameHost {
            request.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        for (field, value) in headers where request.value(forHTTPHeaderField: field) == nil {
            if !sameHost, field.caseInsensitiveCompare("Cookie") == .orderedSame { continue }
            request.setValue(value, forHTTPHeaderField: field)
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            state.withLock { $0.error = FetchError.invalidResponse("not an HTTP response") }
            return completionHandler(.cancel)
        }
        state.withLock { $0.response = response }
        guard (200..<300).contains(response.statusCode) else {
            state.withLock { $0.errorBody = Data() }
            return completionHandler(.allow)
        }
        do {
            if try onResponse(response) { return completionHandler(.allow) }
            state.withLock { $0.stoppedAfterResponse = true }
        } catch {
            state.withLock { $0.error = error }
        }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        enum Next { case deliver, stop, ignore }
        let next = state.withLock { state -> Next in
            if state.completed || state.error != nil { return .ignore }
            guard var body = state.errorBody else { return .deliver }
            body.append(data.prefix(Self.errorBodyLimit - body.count))
            state.errorBody = body
            return body.count >= Self.errorBodyLimit ? .stop : .ignore
        }
        switch next {
        case .ignore:
            return
        case .stop:
            dataTask.cancel()
        case .deliver:
            if streamByteBudget != nil {
                enqueue(data, task: dataTask)
                return
            }
            do {
                try onData(data)
            } catch {
                state.withLock { $0.error = error }
                dataTask.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        state.withLock {
            $0.completed = true
            $0.completionError = error
            // 网络失败撤销预算等待时，不让 consumer 的 CancellationError 掩盖原始传输原因。
            if let error, $0.consumer != nil, $0.error == nil { $0.error = FetchError(error) }
        }
        if error != nil { cancelConsumer() }
        resumeIfCompleted()
    }

    /// 暂停真实任务施加网络背压；暂停途中仍可能有已收回调，所有块共享固定上限。
    private func enqueue(_ data: Data, task: URLSessionDataTask) {
        let shouldCancel = state.withLock { value -> Bool in
            guard !value.completed, value.error == nil else { return false }
            guard data.count <= Self.streamBufferLimit - value.bufferedBytes else {
                value.error = FetchError.streamBufferExceeded
                return true
            }
            value.buffered.append(data); value.bufferedBytes += data.count
            if !value.suspended { task.suspend(); value.suspended = true }
            if value.consumer == nil {
                value.consumer = Task { [weak self] in await self?.consume(task: task) }
            }
            return false
        }
        if shouldCancel { cancelConsumer(); task.cancel() }
    }

    /// 每个请求只有一个消费任务；一次最多 32 KiB 领取额度并同步落盘，EOF 必须等待全部块排空。
    private func consume(task: URLSessionDataTask) async {
        guard let streamByteBudget else { return }
        do {
            while true {
                try Task.checkCancellation()
                let next = state.withLock { value -> (Data?, Bool) in
                    if !value.buffered.isEmpty { return (value.buffered.removeFirst(), false) }
                    value.consumer = nil
                    let resume = value.suspended && !value.completed && value.error == nil
                    value.suspended = false
                    return (nil, resume)
                }
                guard let data = next.0 else {
                    if next.1 { task.resume() }
                    resumeIfCompleted()
                    return
                }
                var offset = 0
                while offset < data.count {
                    try Task.checkCancellation()
                    let length = min(32 * 1024, data.count - offset)
                    try await streamByteBudget.consume(length, direction: .download)
                    try Task.checkCancellation()
                    try autoreleasepool { try onData(data.subdata(in: offset..<(offset + length))) }
                    offset += length
                }
                state.withLock { $0.bufferedBytes -= data.count }
            }
        } catch {
            state.withLock {
                if $0.error == nil { $0.error = error }
                $0.buffered.removeAll(); $0.bufferedBytes = 0; $0.consumer = nil
            }
            task.cancel()
            resumeIfCompleted()
        }
    }

    private func cancelConsumer() { state.withLock { $0.consumer?.cancel() } }

    /// 完成与 continuation 注册无论谁先发生，结果都只交付一次。
    private func resumeIfCompleted() {
        let completed = state.withLock { state -> State? in
            guard state.completed, state.consumer == nil else { return nil }
            defer { state.continuation = nil }
            return state
        }
        guard let state = completed, let continuation = state.continuation else { return }
        if let recorded = state.error {
            continuation.resume(throwing: recorded)
        } else if let response = state.response, let body = state.errorBody {
            let message = String(decoding: body, as: UTF8.self)
            continuation.resume(throwing: FetchError.http(status: response.statusCode, body: message))
        } else if let response = state.response, state.stoppedAfterResponse || state.completionError == nil {
            continuation.resume(returning: response)
        } else {
            continuation.resume(throwing: FetchError(state.completionError ?? URLError(.badServerResponse)))
        }
    }
}
