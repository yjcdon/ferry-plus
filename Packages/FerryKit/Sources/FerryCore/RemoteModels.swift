import Foundation
import BaiduKit
import QuarkKit

/// 不同网盘的远端定位方式，不将夸克 fid 当作路径。
public enum RemoteReference: Codable, Sendable, Hashable {
    case baidu(path: String, fsID: Int64)
    case quark(fid: String)

    public var provider: Provider {
        switch self { case .baidu: .baidu; case .quark: .quark }
    }
    public var identifier: String {
        switch self { case .baidu(let path, _): path; case .quark(let fid): fid }
    }
}

/// 文件树、任务与适配器共同使用的条目。分享文件令牌只存在于短期分享会话。
public struct RemoteEntry: Codable, Sendable, Hashable, Identifiable {
    public let reference: RemoteReference
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedAt: Date?
    public let md5: String?
    /// 分享根目录内的上层路径；用于部分选择时保留分享中的目录结构。
    public let relativeDirectory: String?
    public var id: String { reference.identifier }
    public var path: String { reference.identifier }
    public init(reference: RemoteReference, name: String, isDirectory: Bool, size: Int64,
                modifiedAt: Date? = nil, md5: String? = nil, relativeDirectory: String? = nil) {
        self.reference = reference; self.name = name; self.isDirectory = isDirectory
        self.size = size; self.modifiedAt = modifiedAt
        self.md5 = md5
        self.relativeDirectory = relativeDirectory
    }
    private enum CodingKeys: String, CodingKey { case reference, name, isDirectory, size, modifiedAt, md5, path, fsID, relativeDirectory }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let reference = try c.decodeIfPresent(RemoteReference.self, forKey: .reference) { self.reference = reference }
        else { reference = .baidu(path: try c.decode(String.self, forKey: .path), fsID: try c.decode(Int64.self, forKey: .fsID)) }
        name = try c.decode(String.self, forKey: .name)
        isDirectory = try c.decode(Bool.self, forKey: .isDirectory)
        size = try c.decode(Int64.self, forKey: .size)
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt)
        md5 = try c.decodeIfPresent(String.self, forKey: .md5)
        relativeDirectory = try c.decodeIfPresent(String.self, forKey: .relativeDirectory)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reference, forKey: .reference); try c.encode(name, forKey: .name)
        try c.encode(isDirectory, forKey: .isDirectory); try c.encode(size, forKey: .size)
        try c.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
        try c.encodeIfPresent(md5, forKey: .md5)
        try c.encodeIfPresent(relativeDirectory, forKey: .relativeDirectory)
    }
}

/// 用户分享信息，可持久化；不包含服务端 stoken 或 Cookie。
public struct DiskShareLink: Codable, Sendable, Hashable {
    public let provider: Provider
    public let code: String
    public let password: String?
    public var surl: String { "\(provider.rawValue):\(code)" }
    public var url: URL {
        URL(string: provider == .baidu ? "https://pan.baidu.com/s/1\(code)" : "https://pan.quark.cn/s/\(code)")!
    }
    public init(provider: Provider, code: String, password: String? = nil) {
        self.provider = provider; self.code = code; self.password = password
    }
    private enum CodingKeys: String, CodingKey { case provider, code, password, surl }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? .baidu
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? c.decode(String.self, forKey: .surl)
        password = try c.decodeIfPresent(String.self, forKey: .password)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider); try c.encode(code, forKey: .code)
        try c.encodeIfPresent(password, forKey: .password)
    }
    /// 仅在输入边界解析两家支持的分享格式。
    public static func parse(_ text: String) -> Self? {
        if let link = BaiduKit.ShareLink.parse(text) {
            return Self(provider: .baidu, code: link.surl, password: link.password)
        }
        if let link = try? QuarkShareLink.parse(text) {
            return Self(provider: .quark, code: link.id, password: link.passcode)
        }
        return nil
    }
}

/// 打开窗口期间的分享句柄；客户端内部持有服务端会话，不写入任务。
public struct DiskShareSession: Sendable {
    public let link: DiskShareLink
    public let password: String?
    public let account: AccountKey
    public let title: String
    public let handle: UUID
    public init(link: DiskShareLink, password: String?, account: AccountKey, title: String, handle: UUID = UUID()) {
        self.link = link; self.password = password; self.account = account; self.title = title; self.handle = handle
    }
}

/// 分享专用目录和服务端异步转存回执可独立落盘。
public struct TransferDirectory: Codable, Sendable, Hashable {
    public let reference: RemoteReference
    public let name: String
    public init(reference: RemoteReference, name: String) { self.reference = reference; self.name = name }
}
public struct TransferProgress: Codable, Sendable, Hashable {
    public var taskID: String?
    public var submitted: Bool
    public var completed: Bool
    public var batches: [TransferBatchProgress]?
    public init(taskID: String? = nil, submitted: Bool = false, completed: Bool = false,
                batches: [TransferBatchProgress]? = nil) {
        self.taskID = taskID; self.submitted = submitted; self.completed = completed
        self.batches = batches
    }

    public var needsSubmission: Bool { batches.map { $0.contains { !$0.submitted } } ?? !submitted }

    /// 已提交意图在写盘失败时仍未发出 POST，可以安全恢复前态；回执和完成状态不能回滚。
    func introducesSubmissionIntent(comparedTo previous: Self?) -> Bool {
        if let batches {
            return batches.contains { batch in
                batch.submitted && batch.taskID == nil && !batch.completed &&
                    previous?.batches?.first(where: { $0.relativeDirectory == batch.relativeDirectory })?.submitted != true
            }
        }
        return submitted && taskID == nil && !completed && previous?.submitted != true
    }
}

/// 每个分享相对目录的独立转存回执；不含分享令牌，任务恢复只重提明确未提交的组。
public struct TransferBatchProgress: Codable, Sendable, Hashable {
    public let relativeDirectory: String
    public let entryIDs: [String]
    public var destination: RemoteReference?
    public var submitted: Bool
    public var taskID: String?
    public var completed: Bool
    public init(relativeDirectory: String, entryIDs: [String], destination: RemoteReference? = nil,
                submitted: Bool = false, taskID: String? = nil, completed: Bool = false) {
        self.relativeDirectory = relativeDirectory; self.entryIDs = entryIDs; self.destination = destination
        self.submitted = submitted; self.taskID = taskID; self.completed = completed
    }
}

/// 引擎的应用上下文只含来源、账号和远端身份，不保存下载直链。
public struct DownloadContext: Codable, Sendable, Hashable {
    public let version: Int
    public let account: AccountKey
    public let reference: RemoteReference
    public let size: Int64
    public let md5: String?
    public init(account: AccountKey, reference: RemoteReference, size: Int64, md5: String? = nil) {
        version = 1; self.account = account; self.reference = reference; self.size = size
        self.md5 = md5
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
