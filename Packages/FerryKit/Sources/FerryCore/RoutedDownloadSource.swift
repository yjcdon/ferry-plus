import BaiduKit
import QuarkKit
import DownloadKit
import Foundation
import os

/// 两家共用引擎，解析地址时严格按上下文账号选客户端。
public final class RoutedDownloadSource: DownloadSource {
    private enum Client: Sendable { case baidu(BaiduClient); case quark(QuarkClient) }
    private struct Session: Sendable { let key: AccountKey; let revision: UUID; let client: Client }
    private struct State {
        var sessions: [Provider: Session] = [:]
        var attempts: [String: Int] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    public init() {}
    public func setBaidu(_ client: BaiduClient?, account: AccountKey?) {
        state.withLock { $0.sessions[.baidu] = if let client, let account { Session(key: account, revision: UUID(), client: .baidu(client)) } else { nil } }
    }
    public func setQuark(_ client: QuarkClient?, account: AccountKey?) {
        state.withLock { $0.sessions[.quark] = if let client, let account { Session(key: account, revision: UUID(), client: .quark(client)) } else { nil } }
    }
    public func resolve(_ request: DownloadRequest) async throws -> ResolvedURL {
        let context: DownloadContext
        do { context = try JSONDecoder().decode(DownloadContext.self, from: request.context) }
        catch { throw PermanentLinkError(description: "无法识别下载记录的网盘和账号，请重新添加任务。") }
        guard context.version == 1, context.reference.provider == context.account.provider else {
            throw PermanentLinkError(description: "下载记录来源不一致。")
        }
        let (session, preference) = state.withLock { state in
            let attempt = state.attempts[request.id, default: 0]
            // 重试计数仅影响百度备用主机选择；限制缓存，避免历史任务长期占用内存。
            if state.attempts.count >= 512, state.attempts[request.id] == nil { state.attempts.removeAll(keepingCapacity: true) }
            state.attempts[request.id] = min(attempt + 1, 16)
            return (state.sessions[context.account.provider], attempt)
        }
        guard let session else { throw PermanentLinkError(description: "\(context.account.provider.title)尚未登录。") }
        guard session.key == context.account else { throw PermanentLinkError(description: "任务属于另一个\(context.account.provider.title)账号。") }
        let resolved: ResolvedURL
        do {
            switch (session.client, context.reference) {
            case (.baidu(let client), .baidu(let path, _)):
                let link = try await client.downloadLink(for: path, preference: preference)
                resolved = ResolvedURL(url: link.url, headers: link.headers)
            case (.quark(let client), .quark(let fid)):
                let link = try await client.download(fid: fid)
                if let size = link.size, size != context.size {
                    throw PermanentLinkError(description: "远端文件大小已改变，请重新添加任务。")
                }
                resolved = ResolvedURL(url: link.url, headers: link.headers)
            default: throw PermanentLinkError(description: "客户端与下载来源不一致。")
            }
        } catch let error as BaiduError where BaiduDownloadPolicy.isPermanent(error) {
            throw PermanentLinkError(description: error.localizedDescription)
        } catch let error as QuarkError where Self.isPermanentQuarkFailure(error) {
            throw PermanentLinkError(description: error.localizedDescription)
        }
        guard state.withLock({ $0.sessions[context.account.provider]?.revision }) == session.revision else {
            throw PermanentLinkError(description: "获取地址期间账号会话已变化，请重试。")
        }
        return resolved
    }

    /// 解析接口已明确拒绝时停止自动重试；CDN 直链过期仍由下载引擎刷新。
    private static func isPermanentQuarkFailure(_ error: QuarkError) -> Bool {
        switch error {
        case .loginExpired, .accountChanged, .httpStatus(403), .httpStatus(404),
             .serviceCode("32003"), .serviceFailure(code: "32003", message: _): true
        default: false
        }
    }
}
