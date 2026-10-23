import BaiduKit
import DownloadKit
import Foundation

/// 百度错误策略由共享来源路由使用，不再维护独立下载入口。
enum BaiduDownloadPolicy {
    /// 重试也不会成功的错误：登录失效、文件不存在或无权访问、需要安全验证。
    static func isPermanent(_ error: BaiduError) -> Bool {
        switch error {
        case .loginExpired, .loginStateMissing, .securityVerification, .captchaRequired, .verificationTriggered,
             .fileNotFound, .accessDenied, .invalidNameOrAccessDenied:
            true
        default:
            false
        }
    }

}

/// 引擎遇到它时不再重试，文件下载直接失败。
struct PermanentLinkError: PermanentDownloadSourceError, LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
}
