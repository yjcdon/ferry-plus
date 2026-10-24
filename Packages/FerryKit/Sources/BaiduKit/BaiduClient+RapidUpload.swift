import Foundation
import CryptoKit

/// 一次真实内容证明的范围与协议参数；不含登录凭据或证明字节，不作为可重放的提交记录。
public struct BaiduRapidUploadChallenge: Sendable {
    public static let proofLength: Int64 = 256 * 1024
    public let uploadID: String
    public let path: String
    public let size: Int64
    public let contentMD5: String
    public let sliceMD5: String
    public let timestamp: Int64
    public let range: Range<Int64>

    /// 按官方网页 SDK 的混淆摘要及 uk+摘要+Unix秒公式选择256KiB证明范围。
    public init(session: BaiduUploadSession, accountUK: UInt64, contentMD5: String,
                sliceMD5: String, timestamp: Int64) throws {
        guard session.size > Self.proofLength, accountUK > 0, timestamp >= 0 else {
            throw BaiduUploadError.invalidPlan
        }
        self.uploadID = session.uploadID
        self.path = session.path
        self.size = session.size
        self.timestamp = timestamp
        self.contentMD5 = try Self.obfuscatedMD5(contentMD5)
        self.sliceMD5 = try Self.obfuscatedMD5(sliceMD5)
        let input = String(accountUK) + self.contentMD5 + String(timestamp)
        let digest = Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        let first = UInt64(digest.prefix(8), radix: 16)!
        let offset = Int64(first % UInt64(session.size - Self.proofLength + 1))
        range = offset..<(offset + Self.proofLength)
    }

    /// 复制官方 SDK 的摘要传输变换；这是协议编码，不提供加密或内容完整性保证。
    public static func obfuscatedMD5(_ value: String) throws -> String {
        guard BaiduUploadSession.validMD5(value) else { throw BaiduUploadError.invalidPlan }
        let raw = Array(value.lowercased())
        let reordered = Array(raw[8..<16]) + Array(raw[0..<8]) + Array(raw[24..<32]) + Array(raw[16..<24])
        var encoded = reordered.enumerated().map { index, char in
            String(Int(String(char), radix: 16)! ^ (index & 15), radix: 16)
        }
        encoded[9] = String(UnicodeScalar(103 + Int(encoded[9], radix: 16)!)!)
        return encoded.joined()
    }
}

public enum BaiduRapidUploadError: Error, LocalizedError, Sendable {
    case accountChanged

    public var errorDescription: String? { "百度账号已变化，不能继续原上传会话的快速上传。" }
}

public enum BaiduRapidUploadResult: Sendable {
    /// 服务端明确未命中；只能继续原会话待发片，不能据此声称对象已校验。
    case notMatched
    /// 调用方须保存准确身份，并完整回读 SHA-256 后才能宣称内容验证通过。
    case created(NetdiskEntry)
}

extension BaiduClient {
    /// 原普通会话落盘后尝试快速上传；固定网页 rtype=1，仅供保留两份策略使用。
    /// expectedUK 必须匹配当前账号。reader 须持有源授权并前后核对原身份，准确返回256KiB真实字节。
    /// 调用方在本方法前消费256KiB上传额度并取得连接许可；onSubmitting 仅接收实际 form 字节数并持久化
    /// 独立 rapid pending 意图，不等待限速。只有 HTTP 成功的业务 errno=404 表示未命中；未知结果不回落或重放。
    public func rapidUpload(_ upload: BaiduUploadSession, expectedUK: UInt64,
                            contentMD5: String, sliceMD5: String,
                            onSubmitting: @Sendable (Int) async throws -> Void,
                            readProof: @Sendable (Range<Int64>) async throws -> Data) async throws -> BaiduRapidUploadResult {
        guard expectedUK > 0, upload.size > BaiduRapidUploadChallenge.proofLength else {
            throw BaiduUploadError.invalidPlan
        }
        let user = try await fetchUserInfo()
        guard user.uk > 0 else { throw BaiduError.loginExpired }
        guard UInt64(user.uk) == expectedUK else { throw BaiduRapidUploadError.accountChanged }
        let token = try await fetchBDStoken()
        let challenge = try BaiduRapidUploadChallenge(session: upload, accountUK: UInt64(user.uk),
            contentMD5: contentMD5, sliceMD5: sliceMD5, timestamp: Int64(Date().timeIntervalSince1970))
        let proof = try await readProof(challenge.range)
        guard Int64(proof.count) == BaiduRapidUploadChallenge.proofLength else { throw BaiduUploadError.invalidPlan }
        try Task.checkCancellation()
        let url = URLEncoding.url(Host.pan + "/api/rapidupload", [
            ("rtype", "1"), ("app_id", Host.panAppID), ("channel", "chunlei"),
            ("web", "1"), ("clienttype", "0"), ("bdstoken", token)
        ])
        let parent = (upload.path as NSString).deletingLastPathComponent
        let fields = [
            ("uploadid", upload.uploadID), ("path", upload.path), ("target_path", parent == "/" ? "/" : parent + "/"),
            ("content-length", String(upload.size)), ("content-md5", challenge.contentMD5), ("slice-md5", challenge.sliceMD5),
            ("data_time", String(challenge.timestamp)), ("data_offset", String(challenge.range.lowerBound)),
            ("data_content", proof.base64EncodedString())
        ]
        let request = BaiduRequest.form(fields, url: url, endpoint: .pcsFile, cookies: cookies(),
                                        headers: ["User-Agent": UserAgent.netdisk, "Referer": Host.pan + "/"])
        guard let body = request.body else { throw BaiduUploadError.invalidPlan }
        try await onSubmitting(body.count)
        let (json, response) = try await self.json(request)
        guard (200..<300).contains(response.statusCode) else { throw BaiduError.httpStatus(response.statusCode) }
        guard let errno = json["errno"].int else { throw BaiduError.invalidResponse }
        if errno == 404 { return .notMatched }
        guard errno == 0 else {
            throw BaiduError(code: errno, message: json["errmsg"].string ?? json["show_msg"].string, endpoint: .pcsFile)
        }
        let info = json["info"]
        guard let id = info["fs_id"].int64, id > 0, let path = info["path"].string,
              BaiduUploadSession.validPath(path), (path as NSString).deletingLastPathComponent == parent,
              info["size"].int64 == upload.size, info["isdir"].int == 0 else {
            throw BaiduUploadError.unresolvedInstantUpload
        }
        return .created(NetdiskEntry(fsID: id, name: (path as NSString).lastPathComponent,
                                    path: path, isDirectory: false, size: upload.size))
    }
}
