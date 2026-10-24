import Foundation
import os

/// 服务端账号容量，单位为字节；会员失效时已用空间可以超过当前总容量。
public struct QuarkCapacity: Decodable, Sendable, Equatable {
    public let total: Int64
    public let used: Int64

    private enum CodingKeys: String, CodingKey {
        case total = "total_capacity", used = "use_capacity"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decode(Int64.self, forKey: .total)
        used = try container.decode(Int64.self, forKey: .used)
        guard total >= 0, used >= 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Quark capacity values must be nonnegative byte counts."))
        }
    }
}

/// 本机直连的夸克登录客户端。Cookie 按域和路径发送，独立于系统及百度会话。
public actor QuarkClient {
    private let session: URLSession
    private let revoked = OSAllocatedUnfairLock(initialState: false)
    private var cookies: [QuarkCredential.Cookie]
    private var credentialDidChange: (@Sendable (QuarkCredential) async throws -> Void)?

    public init(credential: QuarkCredential? = nil,
                configuration: URLSessionConfiguration = QuarkClient.defaultConfiguration()) {
        cookies = credential?.cookies ?? []
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// 换号或更换网络会话时立即撤销，避免旧适配器恢复等待后继续发起写请求。
    public nonisolated func revoke() {
        revoked.withLock { $0 = true }
        session.invalidateAndCancel()
    }

    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    private static let commonQuery = [("pr", "ucpro"), ("fr", "pc"), ("uc_param_str", "")]

    /// 只读查询账号总容量和已用容量，不把缺失或无效字段解释为零。
    public func capacity() async throws -> QuarkCapacity {
        try await api(path: "/member")
    }

    /// 打开分享时仅取得短期访问令牌，后续目录请求仍独立校验接口结果。
    public func openShare(_ link: QuarkShareLink) async throws -> QuarkShareSession {
        let data: ShareTokenData = try await api(path: "/share/sharepage/token", host: "pan.quark.cn",
            body: ["pwd_id": link.id, "passcode": link.passcode ?? ""])
        guard !data.stoken.isEmpty else { throw QuarkError.invalidResponse }
        return QuarkShareSession(link: link, stoken: data.stoken, title: data.title ?? "夸克分享")
    }

    /// 返回一层完整分享目录；任意分页失败都会终止，不返回部分列表。
    public func listShareDirectory(session: QuarkShareSession, parentFID: String = "0") async throws -> [QuarkEntry] {
        try await list(path: "/share/sharepage/detail", host: "pan.quark.cn", query: [
            ("pwd_id", session.link.id), ("stoken", session.stoken), ("pdir_fid", parentFID),
            ("force", "0"), ("_fetch_sub_dirs", "0"), ("_sort", "file_type:asc,file_name:asc")])
    }

    /// 返回账号目录的全部分页，根目录由夸克 fid 0 表达。
    public func listDirectory(parentFID: String = "0") async throws -> [QuarkEntry] {
        try await list(path: "/file/sort", host: "drive-pc.quark.cn", query: [
            ("pdir_fid", parentFID), ("fetch_all_file", "1"), ("fetch_risk_file_name", "1"),
            ("_sort", "file_type:asc,file_name:asc")])
    }

    /// 创建真实目录并返回服务器分配的 fid；同名冲突由调用方决定如何处理。
    public func createDirectory(name: String, parentFID: String = "0") async throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw QuarkError.invalidSelection }
        let data: CreatedDirectory = try await api(path: "/file", body: [
            "dir_init_lock": false, "dir_path": "", "file_name": name, "pdir_fid": parentFID])
        guard !data.fid.isEmpty, data.fid != "0" else { throw QuarkError.invalidResponse }
        return data.fid
    }

    /// 立即返回服务端转存任务 ID，调用方须先保存回执，再等待最终状态。
    public func submitSave(session: QuarkShareSession, entries: [QuarkEntry], destinationFID: String,
                           parentFID: String = "0") async throws -> String {
        guard !entries.isEmpty, !destinationFID.isEmpty,
              entries.allSatisfy({ !$0.fid.isEmpty && !($0.shareFIDToken ?? "").isEmpty }) else { throw QuarkError.invalidSelection }
        let data: TaskReceipt = try await api(path: "/share/sharepage/save", body: [
            "fid_list": entries.map(\.fid), "fid_token_list": entries.map { $0.shareFIDToken! },
            "to_pdir_fid": destinationFID, "pwd_id": session.link.id, "stoken": session.stoken,
            "pdir_fid": parentFID, "scene": "link"])
        guard !data.task_id.isEmpty else { throw QuarkError.invalidResponse }
        return data.task_id
    }

    /// 独立查询已提交任务，适用于重启后核对尚未确认的转存。
    public func queryTask(id: String, retryIndex: Int = 0) async throws -> QuarkTransferTask {
        let data: TaskData = try await api(path: "/task", query: [("task_id", id), ("retry_index", String(retryIndex))])
        let status: QuarkTransferTask.Status
        switch data.status { case 0, 1: status = .pending; case 2: status = .completed; case 3, 4: status = .failed
        default: throw QuarkError.invalidResponse }
        return QuarkTransferTask(id: id, status: status, savedFIDs: data.save_as?.save_as_top_fids ?? [])
    }

    /// 有界轮询可取消；停止等待不会撤销服务端任务，任务 ID 仍可再次查询。
    public func waitForTask(id: String, maxAttempts: Int = 60, interval: Duration = .seconds(1)) async throws -> QuarkTransferTask {
        guard maxAttempts > 0, interval > .zero else { throw QuarkError.invalidSelection }
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            let task = try await queryTask(id: id, retryIndex: attempt)
            switch task.status {
            case .completed: return task
            case .failed: throw QuarkError.taskFailed(id)
            case .pending: if attempt + 1 < maxAttempts { try await Task.sleep(for: interval) }
            }
        }
        throw QuarkError.taskTimedOut(id)
    }

    /// 获取一个文件的原始下载地址、请求头和内容身份；不使用视频转码地址。
    public func download(fid: String) async throws -> QuarkDownload {
        let items: [DownloadData] = try await api(path: "/file/download", host: "drive.quark.cn", body: ["fids": [fid]])
        guard items.count == 1, let item = items.first, item.fid == nil || item.fid == fid,
              let url = URL(string: item.download_url), url.scheme == "https", url.host != nil else { throw QuarkError.invalidResponse }
        // 下载地址可落在独立 CDN；只发送按域和路径适用的 Cookie，不把登录凭据扩散到第三方域。
        let header = cookies.filter { matches($0, url: url) }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        var headers = ["User-Agent": Self.userAgent, "Referer": "https://pan.quark.cn/"]
        if !header.isEmpty { headers["Cookie"] = header }
        return QuarkDownload(url: url, headers: headers,
            fid: fid, size: item.size, md5: item.md5, updatedAt: item.updated_at.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    /// 只删除调用方明确提供的 fid，使用移动到网盘回收站的 action_type 1。
    public func delete(fids: [String]) async throws {
        guard !fids.isEmpty, fids.allSatisfy({ !$0.isEmpty && $0 != "0" }) else { throw QuarkError.invalidSelection }
        let body = try JSONSerialization.data(withJSONObject: [
            "action_type": 1, "filelist": fids, "exclude_fids": [String]()])
        let response: Envelope<DeleteData> = try await json(host: "drive.quark.cn", path: "/1/clouddrive/file/delete",
            query: Self.commonQuery, body: body)
        guard response.status == 200, response.code?.text == "0" else { throw response.error }
        if let taskID = response.data?.task_id, !taskID.isEmpty {
            _ = try await waitForTask(id: taskID)
        }
    }

    private func list(path: String, host: String, query: [(String, String)]) async throws -> [QuarkEntry] {
        let pageSize = 100
        let requestedParent = query.first(where: { $0.0 == "pdir_fid" })?.1
        // 分享根 0 是虚拟视图，根条目的 pdir_fid 可为发布者账号中的真实父目录。
        let isVirtualShareRoot = path == "/share/sharepage/detail" && requestedParent == "0"
        var entries: [QuarkEntry] = []
        var ids = Set<String>()
        for page in 1...10_000 {
            try Task.checkCancellation()
            let response: Envelope<FileListData> = try await json(host: host, path: "/1/clouddrive" + path,
                query: Self.commonQuery + query + [("_page", String(page)), ("_size", String(pageSize)), ("_fetch_total", "1")])
            guard response.status == 200, response.code?.text == "0" else { throw response.error }
            guard let data = response.data else { throw QuarkError.invalidResponse }
            let converted = try data.list.map { try $0.entry() }
            for entry in converted {
                if !isVirtualShareRoot, let parent = entry.parentFID, let requestedParent,
                   parent != requestedParent { throw QuarkError.invalidResponse }
                guard ids.insert(entry.fid).inserted else { throw QuarkError.invalidResponse }
                entries.append(entry)
            }
            if let total = response.metadata?._total {
                guard total >= entries.count else { throw QuarkError.invalidResponse }
                if entries.count == total { return entries }
                guard !converted.isEmpty else { throw QuarkError.invalidResponse }
            } else if converted.count < pageSize { return entries }
        }
        throw QuarkError.invalidResponse
    }

    private func api<T: Decodable>(path: String, host: String = "drive-pc.quark.cn", query: [(String, String)] = [],
                                   body: [String: Any]? = nil) async throws -> T {
        let encoded = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let response: Envelope<T> = try await json(host: host, path: "/1/clouddrive" + path,
            query: Self.commonQuery + query, body: encoded)
        guard response.status == 200, response.code?.text == "0" else {
            if path == "/share/sharepage/token" {
                switch response.code?.text {
                case "41008": throw QuarkError.shareRequiresCode
                case "41007", "41009", "24000": throw QuarkError.invalidPasscode
                case "41010", "41012", "24001": throw QuarkError.shareUnavailable
                default: break
                }
            }
            throw response.error
        }
        guard let data = response.data else { throw QuarkError.invalidResponse }
        return data
    }

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
        // URLComponents 按 URL 标准保留 +，服务端表单查询解析却会把它当空格。
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    private func json<T: Decodable>(host: String, path: String,
                                    query: [(String, String)], body: Data? = nil) async throws -> Envelope<T> {
        let data = try await send(Self.url(host: host, path: path, query: query), body: body)
        do { return try JSONDecoder().decode(Envelope<T>.self, from: data) }
        catch { throw QuarkError.invalidResponse }
    }

    /// 手动处理有限重定向，逐跳收集 Cookie，并禁止凭据发往夸克域以外。
    private func send(_ initialURL: URL, body: Data? = nil) async throws -> Data {
        var url = initialURL
        var payload = body
        for _ in 0..<6 {
            try Task.checkCancellation()
            guard !revoked.withLock({ $0 }) else { throw CancellationError() }
            guard url.scheme == "https", let host = url.host,
                  host == "quark.cn" || host.hasSuffix(".quark.cn") else { throw QuarkError.unsafeRedirect }
            var request = URLRequest(url: url)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
            request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
            if let payload {
                request.httpMethod = "POST"
                request.httpBody = payload
                request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            }
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
                if [301, 302, 303].contains(http.statusCode) { payload = nil }
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
    let metadata: Metadata?
    let message: String?

    private enum CodingKeys: String, CodingKey { case status, code, success, data, metadata, message, msg }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(Int.self, forKey: .status)
        code = try container.decodeIfPresent(Scalar.self, forKey: .code)
        success = try container.decodeIfPresent(Bool.self, forKey: .success)
        metadata = try container.decodeIfPresent(Metadata.self, forKey: .metadata)
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? container.decodeIfPresent(String.self, forKey: .msg)
        let succeeded = (status == 200 && code?.text == "0") ||
            success == true || code?.text == "OK"
        // 失败响应的 data 与成功模型不同，先保留业务码；成功响应仍严格解码。
        data = succeeded ? try container.decodeIfPresent(T.self, forKey: .data) : nil
    }

    var error: QuarkError {
        if ["401", "403", "41013", "31001", "20002", "NOT_LOGIN", "UNLOGIN", "UNAUTHORIZED"].contains(code?.text) {
            return .loginExpired
        }
        if let message, !message.isEmpty { return .serviceFailure(code: code?.text ?? "unknown", message: message) }
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

private struct Metadata: Decodable { let _total: Int? }
private struct ShareTokenData: Decodable { let stoken: String; let title: String? }
private struct CreatedDirectory: Decodable { let fid: String }
private struct TaskReceipt: Decodable { let task_id: String }
private struct DeleteData: Decodable { let task_id: String? }
private struct TaskData: Decodable {
    let status: Int
    let save_as: SavedFiles?
    struct SavedFiles: Decodable { let save_as_top_fids: [String] }
}
private struct DownloadData: Decodable {
    let fid: String?
    let download_url: String
    let size: Int64?
    let md5: String?
    let updated_at: Double?
}
private struct FileListData: Decodable { let list: [FileData] }
private struct FileData: Decodable {
    let fid: String
    let file_name: String
    let dir: Bool?
    let file: Bool?
    let file_type: Int?
    let size: Int64?
    let updated_at: Double?
    let l_updated_at: Double?
    let md5: String?
    let share_fid_token: String?
    let pdir_fid: String?

    func entry() throws -> QuarkEntry {
        guard !fid.isEmpty, !file_name.isEmpty else { throw QuarkError.invalidResponse }
        let directory: Bool
        if let dir { directory = dir }
        else if let file { directory = !file }
        else if let file_type { directory = file_type == 0 }
        else { throw QuarkError.invalidResponse }
        guard directory || size != nil, (size ?? 0) >= 0 else { throw QuarkError.invalidResponse }
        return QuarkEntry(fid: fid, name: file_name, isDirectory: directory, size: size ?? 0,
            updatedAt: (updated_at ?? l_updated_at).map { Date(timeIntervalSince1970: $0 / 1000) },
            md5: md5, shareFIDToken: share_fid_token, parentFID: pdir_fid)
    }
}
