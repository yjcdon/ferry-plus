import Foundation

/// 任务及会话的实际网盘来源；“全部网盘”由界面筛选表达。
public enum Provider: String, Codable, Sendable, CaseIterable, Identifiable {
    case baidu
    case quark

    public var id: Self { self }
    public var title: String { self == .baidu ? "百度网盘" : "夸克网盘" }

    /// 固定根目录引用供浏览与上传共用，不替代调用方已选定的目录。
    public var rootReference: RemoteReference {
        switch self {
        case .baidu: .baidu(path: "/", fsID: 0)
        case .quark: .quark(fid: "0")
        }
    }
}

/// 昵称变化不影响账号归属。
public struct AccountKey: Codable, Sendable, Hashable {
    public let provider: Provider
    public let accountID: String

    public init(provider: Provider, accountID: String) {
        self.provider = provider
        self.accountID = accountID
    }
}

/// 界面只读取账号摘要，不读取凭据。
public struct AccountSummary: Sendable {
    public let key: AccountKey
    public let name: String

    public init(key: AccountKey, name: String) {
        self.key = key
        self.name = name
    }
}
