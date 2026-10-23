import Foundation

/// 夸克真实文件身份；分享令牌仅用于当前分享会话。
public struct QuarkEntry: Codable, Hashable, Sendable, Identifiable {
    public let fid: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let updatedAt: Date?
    public let md5: String?
    public let shareFIDToken: String?
    public let parentFID: String?
    public var id: String { fid }
    public init(fid: String, name: String, isDirectory: Bool, size: Int64 = 0,
                updatedAt: Date? = nil, md5: String? = nil, shareFIDToken: String? = nil, parentFID: String? = nil) {
        self.fid = fid; self.name = name; self.isDirectory = isDirectory; self.size = size
        self.updatedAt = updatedAt; self.md5 = md5; self.shareFIDToken = shareFIDToken; self.parentFID = parentFID
    }
}

/// 可保存的分享地址，不携带服务端访问令牌。
public struct QuarkShareLink: Codable, Hashable, Sendable {
    public let id: String
    public let passcode: String?
    public var url: URL { URL(string: "https://pan.quark.cn/s/" + id)! }
    public init(id: String, passcode: String? = nil) { self.id = id; self.passcode = passcode }
    /// 同时识别官方链接和常见分享文案；仅接受夸克官方域名。
    public static func parse(_ text: String) throws -> Self {
        let regex = try NSRegularExpression(pattern: #"https?://pan\.quark\.cn/s/([A-Za-z0-9]+)(?:[^\s，。；"<>]*)"#, options: .caseInsensitive)
        let full = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: full),
              let idRange = Range(match.range(at: 1), in: text),
              let urlRange = Range(match.range, in: text) else { throw QuarkError.invalidShareLink }
        let components = URLComponents(string: String(text[urlRange]))
        var code = components?.queryItems?.first { ["pwd", "passcode", "password", "pw"].contains($0.name.lowercased()) }?.value
        if code == nil {
            let codeRegex = try NSRegularExpression(pattern: #"(?:提取码|提取碼|访问码|密[码碼])\s*[:：]?\s*([A-Za-z0-9]{4})(?![A-Za-z0-9])"#)
            if let m = codeRegex.firstMatch(in: text, range: full), let range = Range(m.range(at: 1), in: text) { code = String(text[range]) }
        }
        return Self(id: String(text[idRange]), passcode: code)
    }
}

/// 仅驻留内存的分享访问会话。
public struct QuarkShareSession: Sendable {
    public let link: QuarkShareLink
    public let stoken: String
    public let title: String
}

/// 已提交转存任务的服务端进度，可通过任务 ID 独立恢复查询。
public struct QuarkTransferTask: Sendable {
    public enum Status: Sendable { case pending, completed, failed }
    public let id: String
    public let status: Status
    public let savedFIDs: [String]
}

/// 短期下载地址和内容身份；请求头不能写入任务持久化数据。
public struct QuarkDownload: Sendable {
    public let url: URL
    public let headers: [String: String]
    public let fid: String
    public let size: Int64?
    public let md5: String?
    public let updatedAt: Date?
}
