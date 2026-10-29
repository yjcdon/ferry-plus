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
    case serviceFailure(code: String, message: String)
    case loginExpired
    case accountChanged
    case missingIdentity
    case missingCredential
    case unsafeRedirect
    case invalidShareLink
    case invalidSelection
    case taskTimedOut(String)
    case taskFailed(String, reason: String? = nil)
    case shareRequiresCode
    case invalidPasscode
    case shareUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "夸克服务响应异常，请稍后重试。"
        case .httpStatus(403): "夸克拒绝访问（HTTP 403），请在夸克官方页面确认该文件和账号的访问权限。"
        case .httpStatus(404): "夸克请求的资源不存在（HTTP 404），请在夸克官方页面确认文件或分享是否仍然可用。"
        case .httpStatus(429): "夸克请求过于频繁（HTTP 429），请降低并发数，稍后重试。"
        case .httpStatus(let code): "夸克请求失败（HTTP \(code)），请稍后重试。"
        case .serviceCode(let code): Self.serviceDescription(code: code, message: nil)
        case .serviceFailure(let code, let message): Self.serviceDescription(code: code, message: message)
        case .loginExpired: "夸克登录已失效，请在官方页面重新登录。"
        case .accountChanged: "返回的夸克账号与已保存账号不同，请重新登录。"
        case .missingIdentity: "登录确认失败，请重新登录。"
        case .missingCredential: "请重新登录夸克网盘。"
        case .unsafeRedirect: "登录地址异常，请重新登录。"
        case .invalidShareLink: "请输入有效的夸克网盘分享链接。"
        case .invalidSelection: "夸克文件选择或目录身份无效，请重新打开文件列表。"
        case .taskTimedOut(let id): "夸克转存仍在处理中（任务 \(id)），稍后可继续核对。"
        case .taskFailed(let id, let reason):
            if let reason { "上一次夸克转存失败：\(reason)（任务 \(id) 已停止。）" }
            else { "上一次夸克转存失败（任务 \(id) 已停止）。" }
        case .shareRequiresCode: "这个夸克分享需要提取码，请填写后重试。"
        case .invalidPasscode: "夸克分享提取码不正确，请检查后重试。"
        case .shareUnavailable: "请检查分享链接并重新打开。"
        }
    }

    /// 将服务端业务失败转为可操作的说明；原始消息仍保存在错误关联值中供诊断。
    private static func serviceDescription(code: String, message: String?) -> String {
        if code == "32003" {
            // 已通过只读容量接口确认：账号已用容量超过当前总容量时返回此码。
            return "夸克网盘空间不足（业务码 32003）。请在夸克官方页面检查可用空间和空间权益，处理后再重试。"
        }
        guard let message else { return "夸克请求未成功（业务码 \(code)），请稍后重试。" }
        // 有些接口返回未替换参数的模板；保留原因文字，不把模板当成完整的服务端说明。
        let reason = message.replacingOccurrences(of: #"\{\d+\}"#, with: "参数未提供", options: .regularExpression)
        return "夸克请求未成功：\(reason)（业务码 \(code)）。"
    }
}
