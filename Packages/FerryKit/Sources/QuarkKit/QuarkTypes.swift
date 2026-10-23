import Foundation

/// 夸克账号的稳定身份；昵称只用于展示。
public struct QuarkAccount: Codable, Sendable, Equatable {
    public let id: String
    public let nickname: String
}

/// 独立会话的 Cookie 快照，只能存入钥匙串。
public struct QuarkCredential: Codable, Sendable, Equatable {
    public struct Cookie: Codable, Sendable, Equatable {
        public let name: String
        public let value: String
        public let domain: String
        public let path: String
        public let expires: Date?
        public let secure: Bool

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expires = cookie.expiresDate
            secure = cookie.isSecure
        }
    }

    public let cookies: [Cookie]

    init(cookies: [Cookie]) { self.cookies = cookies }

    /// 从官方页面的私有 Cookie 存储中提取候选凭据，最终有效性仍由接口校验。
    public init(webCookies: [HTTPCookie]) throws {
        let cookies = webCookies.filter {
            let domain = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
            return (domain == "quark.cn" || domain.hasSuffix(".quark.cn")) &&
                ($0.expiresDate.map { $0 > .now } ?? true)
        }
        let names = Set(cookies.filter { !$0.value.isEmpty }.map(\.name))
        guard names.isSuperset(of: ["__pus", "__kps", "__uid"]) else { throw QuarkError.missingCredential }
        self.cookies = cookies.map(Cookie.init)
    }
}

/// 校验过账号和网盘访问能力后才产生的登录结果。
public struct QuarkLogin: Sendable {
    public let account: QuarkAccount
    public let credential: QuarkCredential
    public let verifiedAt: Date
}

public enum QuarkError: LocalizedError, Sendable, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case serviceCode(String)
    case loginExpired
    case accountChanged
    case missingIdentity
    case missingCredential
    case unsafeRedirect

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "夸克接口返回了无法识别的数据，请稍后重试。"
        case .httpStatus(let code): "夸克请求失败（HTTP \(code)）。"
        case .serviceCode(let code): "夸克请求未成功（业务码 \(code)），请稍后重试。"
        case .loginExpired: "夸克登录已失效，请在官方页面重新登录。"
        case .accountChanged: "返回的夸克账号与已保存账号不同，请重新登录。"
        case .missingIdentity: "未取得夸克账号的稳定标识，登录信息尚未保存。"
        case .missingCredential: "未取得完整的夸克会话凭据，请先完成官方网页登录。"
        case .unsafeRedirect: "夸克请求跳转到了不支持的地址，已停止登录。"
        }
    }
}
