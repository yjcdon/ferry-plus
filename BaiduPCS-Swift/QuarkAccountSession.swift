import FerryCore
import Foundation
import Observation
import QuarkKit

/// 夸克登录状态的唯一所有者。界面与自动验证共用客户端和钥匙串条目。
@MainActor @Observable
final class QuarkAccountSession {
    enum State {
        case loggedOut, checking, loggedIn, expired
        case problem(String)

        var title: String {
            switch self {
            case .loggedOut: "未登录"
            case .checking: "正在校验登录…"
            case .loggedIn: "已登录"
            case .expired: "登录已失效"
            case .problem: "登录校验未完成"
            }
        }
    }

    private(set) var account: QuarkAccount?
    private(set) var state: State = .loggedOut
    private(set) var verifiedAt: Date?
    private(set) var problem: String?
    @ObservationIgnored private var client: QuarkClient?
    @ObservationIgnored private var configuration: URLSessionConfiguration
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var loginAttempt: UUID?
    @ObservationIgnored private var hasStarted = false

    var summary: AccountSummary? {
        account.map { AccountSummary(key: AccountKey(provider: .quark, accountID: $0.id),
                                    name: $0.nickname.isEmpty ? "夸克账号 \($0.id)" : $0.nickname) }
    }

    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
        do {
            if let login = try QuarkCredentialStore.load() {
                account = login.account
                client = QuarkClient(credential: login.credential, configuration: configuration)
                state = .checking
            }
        } catch {
            problem = "无法读取夸克登录信息：\(error.localizedDescription)"
            state = .problem(problem!)
        }
    }

    /// 启动时仅恢复本应用保存的凭据；读取失败与网络失败均不伪装成已登录。
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        if client != nil { await revalidate() }
    }

    /// 官方页面交出候选凭据后开始校验，旧窗口和取消后的响应不能提交会话。
    func beginLogin(credential: QuarkCredential) -> (UUID, QuarkClient) {
        let attempt = UUID()
        loginAttempt = attempt
        return (attempt, QuarkClient(credential: credential, configuration: configuration))
    }

    func cancelLogin(_ attempt: UUID) {
        if loginAttempt == attempt { loginAttempt = nil }
    }

    /// 保存前核对登录尝试与取消状态，再发布账号；原有账号在成功前保持不变。
    func completeLogin(client: QuarkClient, attempt: UUID) async throws {
        let login = try await client.validate()
        try Task.checkCancellation()
        guard loginAttempt == attempt else { throw CancellationError() }
        try QuarkCredentialStore.save(StoredQuarkLogin(credential: login.credential, account: login.account))
        revision = UUID()
        self.client = client
        account = login.account
        verifiedAt = login.verifiedAt
        state = .loggedIn
        problem = nil
        loginAttempt = nil
        await observeCookies(client: client, revision: revision)
    }

    /// 界面按钮、启动恢复和命令行验证执行同一只读鉴权流程。
    func revalidate() async {
        guard let client, let account else { return }
        let revision = revision
        state = .checking
        problem = nil
        do {
            let login = try await client.validate(expectedAccountID: account.id)
            try Task.checkCancellation()
            guard self.revision == revision else { return }
            try QuarkCredentialStore.save(StoredQuarkLogin(credential: login.credential, account: login.account))
            self.account = login.account
            verifiedAt = login.verifiedAt
            state = .loggedIn
            await observeCookies(client: client, revision: revision)
        } catch {
            guard self.revision == revision else { return }
            problem = error.localizedDescription
            if let error = error as? QuarkError, error == .loginExpired || error == .accountChanged {
                state = .expired
            } else {
                state = .problem(error.localizedDescription)
            }
        }
    }

    /// 本地退出只清理夸克条目，不触碰百度会话或其他应用的登录。
    func logOut() throws {
        try QuarkCredentialStore.delete()
        revision = UUID()
        loginAttempt = nil
        client = nil
        account = nil
        verifiedAt = nil
        problem = nil
        state = .loggedOut
    }

    /// 代理变更时使用最新凭据替换客户端，旧响应不再写回新会话。
    func updateConfiguration(_ configuration: URLSessionConfiguration) {
        self.configuration = configuration
        revision = UUID()
        loginAttempt = nil
        do {
            if let login = try QuarkCredentialStore.load() {
                client = QuarkClient(credential: login.credential, configuration: configuration)
                Task { await revalidate() }
            }
        } catch {
            problem = error.localizedDescription
            state = .problem(error.localizedDescription)
        }
    }

    /// 不导出 Cookie；验证过程更新的凭据仍由本会话保存。
    func authenticatedClient() throws -> QuarkClient {
        guard case .loggedIn = state, let client else { throw QuarkError.loginExpired }
        return client
    }

    private func observeCookies(client: QuarkClient, revision: UUID) async {
        await client.observeCredentialChanges { [weak self] credential in
            try await self?.saveUpdatedCredential(credential, revision: revision)
        }
    }

    private func saveUpdatedCredential(_ credential: QuarkCredential, revision: UUID) throws {
        guard self.revision == revision, let account else { throw CancellationError() }
        try QuarkCredentialStore.save(StoredQuarkLogin(credential: credential, account: account))
    }

    /// 命令行只输出非敏感验证结果，便于扫码后自动检查会话恢复。
    func verificationReport() throws -> Data {
        let passed: Bool
        if case .loggedIn = state { passed = true } else { passed = false }
        let report = Report(provider: "quark", authenticated: passed, accountID: account?.id,
                            nickname: account?.nickname, verifiedAt: verifiedAt, problem: problem)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    private struct Report: Encodable {
        let provider: String
        let authenticated: Bool
        let accountID: String?
        let nickname: String?
        let verifiedAt: Date?
        let problem: String?
    }
}
