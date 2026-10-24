import AppKit
import QuarkKit
import SwiftUI

/// 与百度一致，直接显示官方登录页；应用只校验和保存页面产生的会话。
struct QuarkLoginView: View {
    static let windowID = "quark-login"
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var session: WebLoginSession?
    @State private var loginTask: Task<Void, Never>?
    @State private var attempt: UUID?
    @State private var errorMessage: String?
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let session {
                    WebViewContainer(webView: session.webView)
                }
                if let loadError = session?.loadError {
                    ContentUnavailableView {
                        Label("无法加载夸克登录页", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("重新加载") { session?.reload() }
                    }
                    .background(.background)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let errorMessage {
                Banner(message: errorMessage) {
                    Button("重新校验") { retry() }
                }
                .background(.bar)
            }
            Divider()
            HStack {
                Button("重新加载") { errorMessage = nil; session?.reload() }
                    .disabled(loginTask != nil)
                if loginTask != nil {
                    ProgressView().controlSize(.small)
                    Text("正在校验账号并保存登录…").foregroundStyle(.secondary)
                } else if session?.isLoading == true {
                    ProgressView().controlSize(.small)
                    Text("正在加载官方页面…").foregroundStyle(.secondary)
                }
                Spacer()
                Text("夸克官方页面").font(.caption).foregroundStyle(.secondary)
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(minWidth: 800, idealWidth: 1000, maxWidth: .infinity,
               minHeight: 600, idealHeight: 720, maxHeight: .infinity)
        .background(WindowReader(window: $window))
        .onChange(of: window) { _, window in window?.isRestorable = false }
        .onAppear {
            guard session == nil else { return }
            let session = WebLoginSession(provider: .quark)
            session.onQuarkCredential = { logIn($0) }
            self.session = session
            session.start()
        }
        .onDisappear {
            session?.stop()
            session = nil
            loginTask?.cancel()
            loginTask = nil
            if let attempt { model.quark.cancelLogin(attempt) }
            attempt = nil
        }
    }

    /// 官方页面完成登录后，使用同一客户端校验账号及网盘权限，通过才保存。
    private func logIn(_ credential: QuarkCredential) {
        guard loginTask == nil else { return }
        errorMessage = nil
        let (attempt, client) = model.quark.beginLogin(credential: credential)
        self.attempt = attempt
        loginTask = Task {
            defer { loginTask = nil }
            do {
                try await model.quark.completeLogin(client: client, attempt: attempt)
                try Task.checkCancellation()
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func retry() {
        errorMessage = nil
        session?.checkAgain()
    }
}

/// 账号二级菜单中的夸克状态及操作，登录状态仍由同一会话维护。
struct QuarkAccountControls: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var errorMessage: String?

    var body: some View {
        if let summary = model.quark.summary {
            Text(summary.name)
        }
        Text(model.quark.state.title)
        if let problem = model.quark.problem { Text(problem).foregroundStyle(.orange) }
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        if model.quark.account == nil {
            Button("登录…") { openWindow(id: QuarkLoginView.windowID) }
        } else {
            if case .expired = model.quark.state {
                Button("重新登录…") { openWindow(id: QuarkLoginView.windowID) }
            }
            if case .problem = model.quark.state {
                Button("重试") { Task { await model.quark.revalidate() } }
            }
            Button("退出登录") {
                do { try model.quark.logOut(); errorMessage = nil }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }

}
