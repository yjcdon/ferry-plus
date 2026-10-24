import Foundation
import CryptoKit
import Darwin

/// 可保存的上传身份；授权上下文与短期签名不得写入普通任务记录。
public struct QuarkUploadSession: Codable, Sendable, Equatable {
    public let taskID: String
    public let fileID: String
    public let uploadID: String
    public let objectKey: String
    public let bucket: String
    public let storageHost: String
    public let parentFID: String
    public let name: String
    public let size: Int64
    public let partSize: Int

    public var partCount: Int { size == 0 ? 1 : Int((size - 1) / Int64(partSize) + 1) }

    private enum CodingKeys: String, CodingKey {
        case taskID, fileID, uploadID, objectKey, bucket, storageHost, parentFID, name, size, partSize
    }

    init(taskID: String, fileID: String, uploadID: String, objectKey: String, bucket: String, storageHost: String,
         parentFID: String, name: String, size: Int64, partSize: Int) throws {
        guard !taskID.isEmpty, !fileID.isEmpty, fileID != "0", !uploadID.isEmpty, !objectKey.isEmpty, !parentFID.isEmpty,
              !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              size >= 0, partSize > 0, partSize <= 64 * 1024 * 1024,
              storageHost.hasSuffix(".quark.cn"),
              storageHost.range(of: #"^[a-zA-Z0-9.-]+$"#, options: .regularExpression) != nil,
              bucket.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil,
              !objectKey.contains("\n"), !objectKey.contains("\r"), !uploadID.contains("\n"),
              !uploadID.contains("\r"), (size == 0 || (size - 1) / Int64(partSize) < 10_000)
        else { throw QuarkError.invalidResponse }
        self.taskID = taskID; self.fileID = fileID; self.uploadID = uploadID; self.objectKey = objectKey
        self.bucket = bucket; self.storageHost = storageHost; self.parentFID = parentFID
        self.name = name; self.size = size; self.partSize = partSize
    }

    /// 恢复记录也必须满足与服务端准备回执相同的身份及分片约束。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(taskID: c.decode(String.self, forKey: .taskID),
            fileID: c.decode(String.self, forKey: .fileID),
            uploadID: c.decode(String.self, forKey: .uploadID), objectKey: c.decode(String.self, forKey: .objectKey),
            bucket: c.decode(String.self, forKey: .bucket), storageHost: c.decode(String.self, forKey: .storageHost),
            parentFID: c.decode(String.self, forKey: .parentFID), name: c.decode(String.self, forKey: .name),
            size: c.decode(Int64.self, forKey: .size), partSize: c.decode(Int.self, forKey: .partSize))
    }
}

/// 仅在内存使用；若恢复需要持久化，由应用的钥匙串保存编码后的不透明数据。
public struct QuarkUploadAuthorizationContext: Sendable {
    fileprivate let authInfo: String
    fileprivate let callback: Data

    /// 返回仅允许保存到 Keychain 的敏感上下文，不包含 OSS 临时签名。
    public func keychainData() throws -> Data {
        try JSONEncoder().encode(Secret(authInfo: authInfo, callback: callback))
    }

    public init(keychainData: Data) throws {
        let secret = try JSONDecoder().decode(Secret.self, from: keychainData)
        guard !secret.authInfo.isEmpty, !secret.callback.isEmpty else { throw QuarkError.invalidResponse }
        authInfo = secret.authInfo; callback = secret.callback
    }

    fileprivate init(authInfo: String, callback: Data) { self.authInfo = authInfo; self.callback = callback }
    private struct Secret: Codable { let authInfo: String; let callback: Data }
}

public struct QuarkUploadPreparation: Sendable {
    public let session: QuarkUploadSession
    public let authorization: QuarkUploadAuthorizationContext
}

/// 秒传标记只证明服务端已完成该任务；调用方仍须核对目标身份并回读校验。
public enum QuarkUploadHashResult: String, Codable, Sendable { case requiresTransfer, instantCompleted }

/// 分片编号从 1 开始；回执只可用于原 uploadID，不是完整文件的内容摘要。
public struct QuarkUploadPartReceipt: Codable, Sendable, Equatable {
    public let uploadID: String
    public let number: Int
    public let size: Int
    public let etag: String
}

/// OSS 错误保留协议错误码与 requestID，不把签名 URL 或凭据带入错误文本。
public struct QuarkStorageError: LocalizedError, Sendable {
    public let status: Int
    public let code: String?
    public let requestID: String?
    public var errorDescription: String? {
        "夸克对象存储请求失败（HTTP \(status)，\(code ?? "无业务码")，请求 \(requestID ?? "无回执")）。"
    }
}

extension QuarkClient {
    /// 创建单个文件上传任务；目录由调用方先创建，分片大小严格采用服务端回执。
    public func prepareUpload(name: String, parentFID: String, size: Int64,
                              createdAt: Date, modifiedAt: Date) async throws -> QuarkUploadPreparation {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              !parentFID.isEmpty, size >= 0, createdAt.timeIntervalSince1970.isFinite,
              modifiedAt.timeIntervalSince1970.isFinite else { throw QuarkError.invalidSelection }
        let createdMilliseconds = try Self.uploadMilliseconds(createdAt)
        let modifiedMilliseconds = try Self.uploadMilliseconds(modifiedAt)
        let envelope: UploadEnvelope<UploadPreData> = try await uploadCall("/file/upload/pre", body: [
            "ccp_hash_update": true, "dir_name": "", "file_name": name,
            "format_type": "application/octet-stream", "l_created_at": createdMilliseconds,
            "l_updated_at": modifiedMilliseconds, "pdir_fid": parentFID, "size": size])
        let data = envelope.data
        guard let partSize = envelope.metadata?.part_size, partSize > 0, partSize <= 64 * 1024 * 1024,
              !data.task_id.isEmpty, !data.upload_id.isEmpty, !data.obj_key.isEmpty,
              !data.bucket.isEmpty, !data.auth_info.isEmpty,
              // 服务端实测下发 http 的存储定位信息；只取受信任主机，真正上传始终构造 HTTPS。
              let base = URLComponents(string: data.upload_url), let scheme = base.scheme,
              ["http", "https"].contains(scheme),
              let host = base.host, host.hasSuffix(".quark.cn"), base.user == nil, base.password == nil,
              base.port == nil, base.query == nil, base.fragment == nil,
              data.bucket.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil,
              !data.obj_key.contains("\n"), !data.obj_key.contains("\r"), !data.upload_id.contains("\n"),
              !data.upload_id.contains("\r") else { throw QuarkError.invalidResponse }
        let callback = try JSONEncoder().encode(data.callback)
        let session = try QuarkUploadSession(taskID: data.task_id, fileID: data.fid, uploadID: data.upload_id,
            objectKey: data.obj_key, bucket: data.bucket, storageHost: host, parentFID: parentFID,
            name: name, size: size, partSize: partSize)
        return QuarkUploadPreparation(session: session,
            authorization: .init(authInfo: data.auth_info, callback: callback))
    }

    /// 提交本地完整摘要协商秒传；未完成明确返回继续分片，不用空回执代替状态。
    public func negotiateUploadHash(session: QuarkUploadSession, md5: String, sha1: String) async throws -> QuarkUploadHashResult {
        guard Self.validHex(md5, count: 32), Self.validHex(sha1, count: 40) else { throw QuarkError.invalidSelection }
        let response: UploadEnvelope<HashData> = try await uploadCall("/file/update/hash", body: [
            "task_id": session.taskID, "md5": md5.lowercased(), "sha1": sha1.lowercased()])
        return response.data.finish ? .instantCompleted : .requiresTransfer
    }

    /// 上传一片已由上层按源文件基准核对的有界字节；不读取或缓存完整文件。
    public func uploadPart(session upload: QuarkUploadSession, authorization: QuarkUploadAuthorizationContext,
                           number: Int, data: Data) async throws -> QuarkUploadPartReceipt {
        guard (1...upload.partCount).contains(number) else { throw QuarkError.invalidSelection }
        let offset = Int64(number - 1) * Int64(upload.partSize)
        let expected = Int(min(Int64(upload.partSize), upload.size - offset))
        guard data.count == expected else { throw QuarkError.invalidSelection }
        let query = [("partNumber", String(number)), ("uploadId", upload.uploadID)]
        let (_, response) = try await storageRequest(upload, authorization: authorization, method: "PUT",
            contentType: "application/octet-stream", query: query, body: data)
        guard let etag = response.value(forHTTPHeaderField: "ETag"), Self.validETag(etag) else { throw QuarkError.invalidResponse }
        let acknowledgedMD5 = etag.hasPrefix("\"") ? String(etag.dropFirst().dropLast()) : etag
        let expectedMD5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard acknowledgedMD5.lowercased() == expectedMD5 else { throw QuarkError.invalidResponse }
        return QuarkUploadPartReceipt(uploadID: upload.uploadID, number: number, size: data.count, etag: etag)
    }

    /// 分页读取原会话已保留的分片；精确核对 Key/uploadID，不把列表 ETag 当成本地内容基准。
    /// 网关 alias 与返回的实际 Bucket 可能不同，实际 Bucket 必须在所有页保持一致。
    public func listUploadParts(session upload: QuarkUploadSession,
                                authorization: QuarkUploadAuthorizationContext) async throws -> [QuarkUploadPartReceipt] {
        let signedQuery = [("uploadId", upload.uploadID)]
        var marker = 0
        var actualBucket: String?
        var receipts: [QuarkUploadPartReceipt] = []
        // 每页必须前进至少一个合法片号，最多 partCount+1 页，记录最多 10,000 片。
        for _ in 0...upload.partCount {
            try Task.checkCancellation()
            var query = signedQuery + [("max-parts", "1000")]
            if marker > 0 { query.append(("part-number-marker", String(marker))) }
            let (data, response) = try await storageRequest(upload, authorization: authorization, method: "GET",
                contentType: "", query: query, body: Data(), signedQuery: signedQuery)
            if String(decoding: data.prefix(4096), as: UTF8.self).contains("<Error>") {
                throw Self.storageError(status: response.statusCode, data: data, requestID: response.value(forHTTPHeaderField: "x-oss-request-id"))
            }
            let page = try QuarkUploadPartsPage(data: data, session: upload, marker: marker)
            guard actualBucket == nil || actualBucket == page.bucket else { throw QuarkError.invalidResponse }
            actualBucket = page.bucket
            receipts.append(contentsOf: page.receipts)
            guard receipts.count <= upload.partCount else { throw QuarkError.invalidResponse }
            if !page.isTruncated { return receipts }
            marker = page.nextMarker
        }
        throw QuarkError.invalidResponse
    }

    /// 按精确片号、长度和上传身份合并；成功后仍需调用 finishUpload 并核对云端文件。
    public func completeUploadParts(session upload: QuarkUploadSession, authorization: QuarkUploadAuthorizationContext,
                                    receipts: [QuarkUploadPartReceipt]) async throws {
        let sorted = receipts.sorted { $0.number < $1.number }
        guard sorted.count == upload.partCount else { throw QuarkError.invalidSelection }
        for (index, receipt) in sorted.enumerated() {
            let expected = Int(min(Int64(upload.partSize), upload.size - Int64(index) * Int64(upload.partSize)))
            guard receipt.uploadID == upload.uploadID, receipt.number == index + 1,
                  receipt.size == expected, Self.validETag(receipt.etag) else { throw QuarkError.invalidSelection }
        }
        let parts = sorted.map { "<Part><PartNumber>\($0.number)</PartNumber><ETag>\(Self.xmlEscape($0.etag))</ETag></Part>" }.joined()
        let body = Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUpload>" + parts + "</CompleteMultipartUpload>").utf8)
        let (responseData, _) = try await storageRequest(upload, authorization: authorization, method: "POST",
            contentType: "application/xml", query: [("uploadId", upload.uploadID)], body: body,
            callback: authorization.callback.base64EncodedString())
        // OSS 某些错误可包装在 HTTP 200 中；检测并保留 XML 错误码。
        if String(decoding: responseData.prefix(4096), as: UTF8.self).contains("<Error>") {
            throw Self.storageError(status: 200, data: responseData, requestID: nil)
        }
    }

    /// 告知网盘合并结束；回执不证明完整内容，调用方须查询准确目标并校验 SHA-256。
    public func finishUpload(session: QuarkUploadSession) async throws {
        let _: UploadEnvelope<EmptyUploadData> = try await uploadCall("/file/upload/finish", body: [
            "obj_key": session.objectKey, "task_id": session.taskID])
    }

    private func uploadCall<T: Decodable>(_ path: String, body: [String: Any]) async throws -> UploadEnvelope<T> {
        var components = URLComponents(string: "https://drive-pc.quark.cn/1/clouddrive" + path)!
        components.queryItems = [URLQueryItem(name: "pr", value: "ucpro"), URLQueryItem(name: "fr", value: "pc"), URLQueryItem(name: "uc_param_str", value: "")]
        let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        let bytes = try await send(components.url!, body: payload)
        return try JSONDecoder().decode(UploadEnvelope<T>.self, from: bytes)
    }

    private func storageRequest(_ upload: QuarkUploadSession, authorization: QuarkUploadAuthorizationContext,
                                method: String, contentType: String, query: [(String, String)], body: Data,
                                callback: String? = nil, signedQuery: [(String, String)]? = nil) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard !revoked.withLock({ $0 }) else { throw CancellationError() }
        let date = Self.storageDate()
        let contentMD5 = method == "POST" ? Data(Insecure.MD5.hash(data: body)).base64EncodedString() : ""
        let userAgent = "aliyun-sdk-js/6.6.1 Chrome 98.0.4758.80 on Windows 10 64-bit"
        let canonicalQuery = (signedQuery ?? query).map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let callbackHeader = callback.map { "x-oss-callback:\($0)\n" } ?? ""
        let authMeta = "\(method)\n\(contentMD5)\n\(contentType)\n\(date)\n\(callbackHeader)x-oss-date:\(date)\nx-oss-user-agent:\(userAgent)\n/\(upload.bucket)/\(upload.objectKey)?\(canonicalQuery)"
        let auth: UploadEnvelope<AuthData> = try await uploadCall("/file/upload/auth", body: [
            "auth_info": authorization.authInfo, "auth_meta": authMeta, "task_id": upload.taskID])
        guard !auth.data.auth_key.isEmpty else { throw QuarkError.invalidResponse }
        var url = URLComponents()
        url.scheme = "https"; url.host = upload.bucket + "." + upload.storageHost; url.path = "/" + upload.objectKey
        url.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let endpoint = url.url else { throw QuarkError.invalidResponse }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        if method != "PUT" { request.httpBody = body }
        request.setValue(auth.data.auth_key, forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        request.setValue(date, forHTTPHeaderField: "x-oss-date")
        request.setValue(userAgent, forHTTPHeaderField: "x-oss-user-agent")
        if !contentMD5.isEmpty { request.setValue(contentMD5, forHTTPHeaderField: "Content-MD5") }
        if let callback { request.setValue(callback, forHTTPHeaderField: "x-oss-callback") }
        try Task.checkCancellation()
        guard !revoked.withLock({ $0 }) else { throw CancellationError() }
        // 使用禁 Cookie 且禁止自动重定向的客户端会话；不经由带网盘 Cookie 的 send。
        let (data, response): (Data, URLResponse)
        if method == "PUT" {
            let bodyFile = try Self.spoolPart(body)
            defer { _ = unlink(bodyFile.path) }
            (data, response) = try await session.upload(for: request, fromFile: bodyFile)
        } else {
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw QuarkError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.storageError(status: http.statusCode, data: data,
                requestID: http.value(forHTTPHeaderField: "x-oss-request-id"))
        }
        return (data, http)
    }

    /// 只暂存一个 PUT 分片，避免系统会话长期持有内存体；文件为随机独占 0600。
    private static func spoolPart(_ data: Data) throws -> URL {
        try autoreleasepool {
            _ = orphanPartsCleaned
            var template = Array((NSTemporaryDirectory() + "ferry-quark-part-\(getpid())-XXXXXX").utf8CString)
            let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let path = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let file = URL(fileURLWithPath: path)
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
                return file
            } catch {
                try? handle.close()
                _ = unlink(file.path)
                throw error
            }
        }
    }

    /// 每个进程首次暂存时回收本用户的已退出实例分片；活进程、旧格式和未知归属均保留。
    /// PID 被复用时暂不回收，留到后续启动确认该 PID 已退出；不承诺立即清理。
    private static let orphanPartsCleaned: Void = {
        let directory = NSTemporaryDirectory()
        let prefix = "ferry-quark-part-"
        // 清理是尽力操作，目录无法枚举时不扩大删除范围，也不阻断当前上传。
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names where name.hasPrefix(prefix) {
            let parts = name.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, let pid = Int32(parts[0]), pid > 0, String(pid) == parts[0],
                  parts[1].utf8.count == 6,
                  parts[1].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { continue }
            let path = directory + name
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else { continue }
            guard kill(pid, 0) == -1, errno == ESRCH else { continue }
            _ = unlink(path)
        }
    }()

    /// 网盘时间戳字段只接受整数毫秒；浮点小数会使实际服务端返回 HTTP 500。
    private static func uploadMilliseconds(_ date: Date) throws -> Int64 {
        let milliseconds = date.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, milliseconds >= Double(Int64.min), milliseconds < Double(Int64.max) else {
            throw QuarkError.invalidSelection
        }
        return Int64(milliseconds)
    }

    private static func validHex(_ text: String, count: Int) -> Bool {
        text.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    private static func validETag(_ value: String) -> Bool {
        let unquoted = value.hasPrefix("\"") && value.hasSuffix("\"") ? String(value.dropFirst().dropLast()) : value
        return validHex(unquoted, count: 32)
    }
    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func storageDate() -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: .now)
    }
    private static func storageError(status: Int, data: Data, requestID: String?) -> QuarkStorageError {
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        func field(_ name: String) -> String? {
            guard let start = text.range(of: "<\(name)>"), let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex) else { return nil }
            return String(text[start.upperBound..<end.lowerBound])
        }
        return QuarkStorageError(status: status, code: field("Code"), requestID: requestID ?? field("RequestId"))
    }
}

private struct UploadEnvelope<T: Decodable>: Decodable {
    let data: T
    let metadata: UploadMetadata?
    private enum CodingKeys: String, CodingKey { case status, code, message, msg, data, metadata }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(Int.self, forKey: .status)
        let code: String
        if let number = try? container.decode(Int.self, forKey: .code) { code = String(number) }
        else { code = try container.decode(String.self, forKey: .code) }
        guard status == 200, code == "0" else {
            if ["401", "403", "41013", "31001", "20002", "NOT_LOGIN", "UNLOGIN", "UNAUTHORIZED"].contains(code) { throw QuarkError.loginExpired }
            let message = try container.decodeIfPresent(String.self, forKey: .message) ?? container.decodeIfPresent(String.self, forKey: .msg)
            if let message, !message.isEmpty { throw QuarkError.serviceFailure(code: code, message: message) }
            throw QuarkError.serviceCode(code)
        }
        data = try container.decode(T.self, forKey: .data)
        metadata = try container.decodeIfPresent(UploadMetadata.self, forKey: .metadata)
    }
}
private struct UploadMetadata: Decodable { let part_size: Int? }
private struct UploadPreData: Decodable {
    let task_id: String; let fid: String; let upload_id: String; let obj_key: String; let bucket: String
    let upload_url: String; let auth_info: String; let callback: [String: UploadJSONValue]
}
private struct HashData: Decodable { let finish: Bool }
private struct AuthData: Decodable { let auth_key: String }
private struct EmptyUploadData: Decodable {}
private enum UploadJSONValue: Codable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: UploadJSONValue]), array([UploadJSONValue]), null
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: UploadJSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([UploadJSONValue].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
