#if DEBUG
import Foundation
import os

/// 验证只允许一个真实窗口（默认 1 MiB）；下一片先挂起，由正式下载流程暂停传输。
nonisolated final class RangeVerificationGate: @unchecked Sendable {
    static let window: Int64 = 1 << 20
    struct Evidence: Encodable, Sendable {
        let offset: Int64
        let endOffset: Int64
        let status: Int
        let expiry: ExpiryMetadata
    }
    /// 仅报告主机和候选到期时长，不保留完整地址、参数值或请求头；候选不等于鉴权期限已被服务端证明。
    struct ExpiryMetadata: Encodable, Sendable {
        let host: String?
        let state: String
        let candidateExpirySeconds: Int64?
        let parameterNames: [String]
        let parameterFormats: [String: String]
    }
    enum Event: Sendable { case boundary; case failed(String) }
    enum Admission { case allow, wait, reject }
    private struct State {
        var bytes: Int64 = 0
        var evidence: [Evidence] = []
        var admitted = false
    }
    let lowerOffset: Int64
    let windowLength: Int64
    let upperOffset: Int64
    let totalSize: Int64
    let configuration: URLSessionConfiguration
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    init(lowerOffset: Int64, totalSize: Int64, configuration: URLSessionConfiguration, window: Int64 = RangeVerificationGate.window) {
        self.lowerOffset = lowerOffset
        windowLength = window
        upperOffset = lowerOffset + window
        self.totalSize = totalSize
        self.configuration = configuration
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
    }

    deinit { continuation.finish() }

    /// 边界请求不发网；只接受本阶段唯一窗口，不允许无边界或重复下载。
    func admit(start: Int64, end: Int64) -> Admission {
        if start == upperOffset {
            continuation.yield(.boundary)
            return .wait
        }
        let accepted = state.withLock { value in
            guard start == lowerOffset, end == upperOffset - 1, !value.admitted else { return false }
            value.admitted = true
            return true
        }
        if !accepted { fail("unexpected_request_range") }
        return accepted ? .allow : .reject
    }

    /// 接受原始服务器头，记录证据；不改写或合成响应头。
    func accept(_ response: HTTPURLResponse) -> Bool {
        guard response.statusCode == 206 else { fail("http_\(response.statusCode)"); return false }
        let expected = "bytes \(lowerOffset)-\(upperOffset - 1)/\(totalSize)"
        guard response.value(forHTTPHeaderField: "Content-Range") == expected,
              response.expectedContentLength < 0 || response.expectedContentLength == windowLength else {
            fail("unexpected_response_range")
            return false
        }
        let expiry = Self.expiryMetadata(response.url)
        state.withLock {
            $0.evidence.append(Evidence(offset: lowerOffset, endOffset: upperOffset,
                                       status: response.statusCode, expiry: expiry))
        }
        return true
    }

    /// 只识别明确命名的 Unix 秒时间戳、显式单位时长及 OSS/AWS 日期加时长；忽略缓存头与不明签名内容。
    static func expiryMetadata(_ url: URL?) -> ExpiryMetadata {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        let recognized = Set(["expires", "expire", "expiry", "expiration", "deadline", "e",
                              "x-oss-expires", "x-oss-date", "x-amz-expires", "x-amz-date"])
        let fields = Dictionary(grouping: items, by: { $0.name.lowercased() })
        let names = Set(items.map(\.name)).sorted()
        var candidates: [TimeInterval] = []
        var formats: [String: String] = [:]
        for name in fields.keys.sorted() where recognized.contains(name) && !name.hasSuffix("-date") {
            guard let entries = fields[name], entries.count == 1, let value = entries[0].value else {
                formats[name] = "ambiguous"
                continue
            }
            guard let seconds = Int64(value) else {
                formats[name] = "unrecognized"
                // 显式带单位的 duration 只有配套唯一签发 epoch 时才构成候选到期时间。
                let multipliers: [Character: Int64] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
                let text = value.lowercased()
                if let unit = text.last, let multiplier = multipliers[unit],
                   let amount = Int64(text.dropLast()), amount > 0, amount <= 604_800 / multiplier {
                    formats[name] = "duration_with_unit"
                    if let times = fields["time"], times.count == 1,
                       let raw = times[0].value, let issued = Int64(raw),
                       (946_684_800...4_102_444_800).contains(issued) {
                        formats["time"] = "epoch_seconds"
                        candidates.append(TimeInterval(issued + amount * multiplier))
                    }
                }
                continue
            }
            formats[name] = "integer_without_epoch"
            // 常规 epoch 秒范围；小数字不能直接当绝对日期，毫秒或其他签名格式不猜测。
            if (946_684_800...4_102_444_800).contains(seconds) {
                formats[name] = "epoch_seconds"
                candidates.append(TimeInterval(seconds))
            } else if name == "x-oss-expires" || name == "x-amz-expires" {
                let dateName = name.replacingOccurrences(of: "-expires", with: "-date")
                guard seconds > 0, seconds <= 7 * 24 * 60 * 60,
                      let dates = fields[dateName], dates.count == 1, let value = dates[0].value else { continue }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .iso8601)
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
                formatter.isLenient = false
                if let issued = formatter.date(from: value) {
                    formats[name] = "duration_seconds"
                    formats[dateName] = "utc_basic_date"
                    candidates.append(issued.timeIntervalSince1970 + TimeInterval(seconds))
                }
            }
        }
        let distinct = Set(candidates)
        let expiry = distinct.count == 1 ? distinct.first : nil
        return ExpiryMetadata(host: url?.host(), state: expiry == nil ? "not_declared" : "candidate",
            candidateExpirySeconds: expiry.map { Int64(($0 - Date().timeIntervalSince1970).rounded(.down)) },
            parameterNames: names, parameterFormats: formats)
    }

    /// 响应体累计不得超出一个窗口；超长块不会交给引擎写盘。
    func acceptBody(count: Int) -> Bool {
        let accepted = state.withLock { value in
            guard Int64(count) <= windowLength - value.bytes else { return false }
            value.bytes += Int64(count)
            return true
        }
        if !accepted { fail("response_body_limit") }
        return accepted
    }

    var bytes: Int64 { state.withLock { $0.bytes } }
    var evidence: [Evidence] { state.withLock { $0.evidence } }
    func fail(_ status: String) { continuation.yield(.failed(status)) }

    /// 有界等待下一片；退出/网络失败不会留下永久等待任务。
    func waitForBoundary() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [events] in
                var iterator = events.makeAsyncIterator()
                guard let event = await iterator.next() else { throw RangeVerificationFailure("cancelled") }
                switch event {
                case .boundary: return
                case .failed(let status): throw RangeVerificationFailure(status)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(45))
                throw RangeVerificationFailure("boundary_timeout")
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

nonisolated struct RangeVerificationFailure: Error, Sendable {
    let status: String
    init(_ status: String) { self.status = status }
}

/// 仅由验证引擎显式安装的传输护栏；底层 URLSession 仍请求真实 CDN，不产生替代数据。
nonisolated final class RangeVerificationProtocol: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    private static let active = OSAllocatedUnfairLock<RangeVerificationGate?>(initialState: nil)
    private struct State {
        var session: URLSession?
        var task: URLSessionDataTask?
        var stopped = false
        var completed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var gate: RangeVerificationGate?

    static func install(_ gate: RangeVerificationGate?) { active.withLock { $0 = gate } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// 无 Range、窗口外请求及已结束的验证均不连接服务器。
    override func startLoading() {
        guard let gate = Self.active.withLock({ $0 }) else { return fail() }
        self.gate = gate
        guard request.httpMethod == "GET", request.url?.scheme == "https",
              let raw = request.value(forHTTPHeaderField: "Range"), raw.hasPrefix("bytes="), raw.count < 80 else {
            gate.fail("missing_range")
            return fail()
        }
        let parts = raw.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int64(parts[0]), let end = Int64(parts[1]), start >= 0, end >= start else {
            gate.fail("invalid_range")
            return fail()
        }
        switch gate.admit(start: start, end: end) {
        case .wait: return
        case .reject: return fail()
        case .allow: break
        }
        let configuration = gate.configuration.copy() as! URLSessionConfiguration
        configuration.protocolClasses = []
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        let canStart = state.withLock { value in
            guard !value.stopped else { return false }
            value.session = session
            value.task = task
            return true
        }
        if canStart { task.resume() } else { session.invalidateAndCancel() }
    }

    /// 引擎正式暂停后 URLSession 取消外层任务，释放挂起请求和底层会话。
    override func stopLoading() {
        let session = state.withLock { value in
            value.stopped = true
            defer { value.session = nil; value.task = nil }
            return value.session
        }
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !state.withLock({ $0.stopped || $0.completed }) else { return completionHandler(.cancel) }
        guard let response = response as? HTTPURLResponse else {
            gate?.fail("invalid_response")
            completionHandler(.cancel)
            return fail()
        }
        guard gate?.accept(response) == true else {
            completionHandler(.cancel)
            return fail()
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !state.withLock({ $0.stopped || $0.completed }) else { return }
        guard gate?.acceptBody(count: data.count) == true else { return fail() }
        client?.urlProtocol(self, didLoad: data)
    }

    /// CDN 跳转沿用正式下载的请求头规则；Cookie 不传播到其他主机。
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest redirect: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard redirect.url?.scheme == "https" else {
            gate?.fail("unsafe_redirect")
            completionHandler(nil)
            return fail()
        }
        var redirect = redirect
        let sameHost = redirect.url?.host()?.lowercased() == request.url?.host()?.lowercased()
        if !sameHost { redirect.setValue(nil, forHTTPHeaderField: "Cookie") }
        for (field, value) in request.allHTTPHeaderFields ?? [:] where redirect.value(forHTTPHeaderField: field) == nil {
            if !sameHost, field.caseInsensitiveCompare("Cookie") == .orderedSame { continue }
            redirect.setValue(value, forHTTPHeaderField: field)
        }
        completionHandler(redirect)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let shouldFinish = state.withLock { value in
            defer { value.session = nil; value.task = nil }
            guard !value.stopped, !value.completed else { return false }
            value.completed = true
            return true
        }
        session.finishTasksAndInvalidate()
        guard shouldFinish else { return }
        if error != nil || gate?.bytes != gate?.windowLength {
            gate?.fail(error == nil ? "short_response" : "network_failure")
            client?.urlProtocol(self, didFailWithError: RangeVerificationFailure("network_failure"))
        } else { client?.urlProtocolDidFinishLoading(self) }
    }

    private func fail() {
        let session = state.withLock { value in
            guard !value.completed, !value.stopped else { return (nil as URLSession?, false) }
            value.completed = true
            defer { value.session = nil; value.task = nil }
            return (value.session, true)
        }
        session.0?.invalidateAndCancel()
        if session.1 { client?.urlProtocol(self, didFailWithError: RangeVerificationFailure("range_guard_rejected")) }
    }
}
#endif
