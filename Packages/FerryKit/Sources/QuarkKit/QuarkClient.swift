import Foundation

/// 本机直连的夸克登录客户端。Cookie 按域和路径发送，独立于系统及百度会话。
public actor QuarkClient {
    private let session: URLSession
    private var cookies: [QuarkCredential.Cookie]
    private var credentialDidChange: (@Sendable (QuarkCredential) async throws -> Void)?

    public init(credential: QuarkCredential? = nil,
                configuration: URLSessionConfiguration = QuarkClient.defaultConfiguration()) {
        cookies = credential?.cookies ?? []
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        return configuration
    }

    /// 登录成功后接入应用凭据存储，后续响应更新 Cookie 时同步保存。
    public func observeCredentialChanges(_ handler: @escaping @Sendable (QuarkCredential) async throws -> Void) {
        credentialDidChange = handler
    }

    /// 供启动恢复和自动验证共同使用；只读取根目录，不写入网盘。
    public func validate(expectedAccountID: String? = nil) async throws -> QuarkLogin {
        let response: Envelope<AccountData> = try await json(
            host: "pan.quark.cn", path: "/account/info", query: [("fr", "pc"), ("platform", "pc")])
        let account = try account(from: response)
        if let expectedAccountID, account.id != expectedAccountID { throw QuarkError.accountChanged }
        try await verifyDriveAccess()
        let credential = currentCredential
        guard !credential.cookies.isEmpty else { throw QuarkError.missingCredential }
        return QuarkLogin(account: account, credential: credential, verifiedAt: .now)
    }

    private func verifyDriveAccess() async throws {
        let response: Envelope<DirectoryData> = try await json(
            host: "drive-pc.quark.cn", path: "/1/clouddrive/file/sort", query: [
                ("pr", "ucpro"), ("fr", "pc"), ("uc_param_str", ""), ("pdir_fid", "0"),
                ("_page", "1"), ("_size", "1"), ("_fetch_total", "1"),
                ("_sort", "file_type:asc,updated_at:desc"),
            ])
        guard response.status == 200, response.code?.text == "0" else { throw response.error }
        guard response.data != nil else { throw QuarkError.invalidResponse }
    }

    private func account(from response: Envelope<AccountData>) throws -> QuarkAccount {
        guard response.success == true || response.code?.text == "OK" else { throw response.error }
        // 此接口在未登录时也会返回 success=true、code=OK、data=null。
        guard let data = response.data else { throw QuarkError.loginExpired }
        if data.uid == nil, data.nickname == nil { throw QuarkError.loginExpired }
        let id = data.uid?.text ?? cookies.first { $0.name == "__uid" && isCurrent($0) }?.value
        guard let id, !id.isEmpty else { throw QuarkError.missingIdentity }
        return QuarkAccount(id: id, nickname: data.nickname ?? "")
    }

    private var currentCredential: QuarkCredential {
        QuarkCredential(cookies: cookies.filter(isCurrent))
    }

    private static func url(host: String, path: String, query: [(String, String)] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    private func json<T: Decodable>(host: String, path: String,
                                    query: [(String, String)]) async throws -> Envelope<T> {
        let data = try await send(Self.url(host: host, path: path, query: query))
        do { return try JSONDecoder().decode(Envelope<T>.self, from: data) }
        catch { throw QuarkError.invalidResponse }
    }

    /// 手动处理有限重定向，逐跳收集 Cookie，并禁止凭据发往夸克域以外。
    private func send(_ initialURL: URL) async throws -> Data {
        var url = initialURL
        for _ in 0..<6 {
            try Task.checkCancellation()
            guard url.scheme == "https", let host = url.host,
                  host == "quark.cn" || host.hasSuffix(".quark.cn") else { throw QuarkError.unsafeRedirect }
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            let header = cookies.filter { matches($0, url: url) }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            if !header.isEmpty { request.setValue(header, forHTTPHeaderField: "Cookie") }
            let data: Data
            let response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            guard let http = response as? HTTPURLResponse else { throw QuarkError.invalidResponse }
            let before = currentCredential
            let fields = http.allHeaderFields.reduce(into: [String: String]()) { result, item in
                if let key = item.key as? String { result[key] = String(describing: item.value) }
            }
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
                let value = QuarkCredential.Cookie(cookie)
                let domain = value.domain.hasPrefix(".") ? String(value.domain.dropFirst()) : value.domain
                guard host == domain || host.hasSuffix("." + domain),
                      domain == "quark.cn" || domain.hasSuffix(".quark.cn") else { continue }
                cookies.removeAll { $0.name == value.name && $0.domain == value.domain && $0.path == value.path }
                if isCurrent(value) { cookies.append(value) }
            }
            if currentCredential != before, let credentialDidChange {
                try await credentialDidChange(currentCredential)
            }
            if [301, 302, 303, 307, 308].contains(http.statusCode) {
                guard let location = http.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                    throw QuarkError.invalidResponse
                }
                url = next
                continue
            }
            if http.statusCode == 401 || http.statusCode == 403 { throw QuarkError.loginExpired }
            guard (200..<300).contains(http.statusCode) else { throw QuarkError.httpStatus(http.statusCode) }
            return data
        }
        throw QuarkError.unsafeRedirect
    }

    private func isCurrent(_ cookie: QuarkCredential.Cookie) -> Bool {
        cookie.expires.map { $0 > .now } ?? true
    }

    private func matches(_ cookie: QuarkCredential.Cookie, url: URL) -> Bool {
        guard isCurrent(cookie), !cookie.secure || url.scheme == "https", let host = url.host else { return false }
        let domainMatches: Bool
        if cookie.domain.hasPrefix(".") {
            let domain = String(cookie.domain.dropFirst())
            domainMatches = host == domain || host.hasSuffix("." + domain)
        } else {
            domainMatches = host == cookie.domain
        }
        let path = url.path.isEmpty ? "/" : url.path
        let pathMatches = path == cookie.path || (path.hasPrefix(cookie.path) &&
            (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
        return domainMatches && pathMatches
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct Envelope<T: Decodable>: Decodable {
    let status: Int?
    let code: Scalar?
    let success: Bool?
    let data: T?

    private enum CodingKeys: String, CodingKey { case status, code, success, data }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(Int.self, forKey: .status)
        code = try container.decodeIfPresent(Scalar.self, forKey: .code)
        success = try container.decodeIfPresent(Bool.self, forKey: .success)
        let succeeded = (status == 200 && code?.text == "0") ||
            success == true || code?.text == "OK"
        // 失败响应的 data 与成功模型不同，先保留业务码；成功响应仍严格解码。
        data = succeeded ? try container.decodeIfPresent(T.self, forKey: .data) : nil
    }

    var error: QuarkError {
        if ["401", "403", "41013", "31001", "NOT_LOGIN", "UNLOGIN", "UNAUTHORIZED"].contains(code?.text) {
            return .loginExpired
        }
        return .serviceCode(code?.text ?? status.map(String.init) ?? "unknown")
    }
}

private struct Scalar: Decodable {
    let text: String
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { text = value }
        else { text = String(try container.decode(Int64.self)) }
    }
}

private struct AccountData: Decodable { let uid: Scalar?; let nickname: String? }
private struct DirectoryData: Decodable { let list: [DirectoryItem] }
private struct DirectoryItem: Decodable {}
