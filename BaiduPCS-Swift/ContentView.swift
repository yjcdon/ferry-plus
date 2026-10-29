import AppKit
import BaiduKit
import FerryCore
import SwiftUI

/// 主窗口：侧边栏、任务列表和详情栏（见 `MainView`），以及主窗口的 sheet。
struct ContentView: View {
    static let windowID = "main"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var hasShownQuarkLogin = false
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        @Bindable var model = model
        MainView()
            .logOutConfirmation(isPresented: $model.isConfirmingMenuLogOut)
            .sheet(item: $model.sheet) { sheet in
                switch sheet {
                case .addLink: AddLinkView().solidSheetSurface()
                }
            }
            .onAppear {
                model.openMainWindow = { [openWindow] in openWindow(id: Self.windowID) }
                model.openLoginWindow = { [openWindow] in openWindow(id: LoginView.windowID) }
                model.openQuarkLoginWindow = { [openWindow] in openWindow(id: QuarkLoginView.windowID) }
                if ProcessInfo.processInfo.arguments.contains("--quark-login"), !hasShownQuarkLogin {
                    hasShownQuarkLogin = true
                    openWindow(id: QuarkLoginView.windowID)
                }
                #if DEBUG
                if DemoData.isEnabled, DemoData.settingsTab != nil { openSettings() }
                if DemoData.isEnabled, let sheet = DemoData.sheet.flatMap(AppModel.Sheet.init(rawValue:)) {
                    model.sheet = sheet
                }
                #endif
            }
    }
}

/// 取得视图所在的窗口。在 macOS 14 上，SwiftUI 不能关闭窗口恢复。
struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindowChange = { window = $0 }
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}

/// 任务列表上方的提示条：加载警告、未登录、登录失效。
struct Banners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let warning = model.coordinator.loadWarning {
                Banner(message: warning) {
                    Button("关闭") { model.coordinator.dismissLoadWarning() }
                }
            }
            if let problem = model.uploadProblem {
                Banner(message: "上传：" + problem) {
                    Button("关闭") { model.uploadProblem = nil }
                }
            }
            if model.account == nil, model.coordinator.jobs.contains(where: { $0.provider == .baidu && $0.isUnfinished }) {
                Banner(message: "请登录百度网盘。") {
                    Button("登录") { model.presentLogin() }
                }
            } else if model.isLoginExpired {
                Banner(message: "请重新登录百度网盘。") {
                    Button("重新登录") { model.presentLogin() }
                }
            }
            if let problem = model.quark.problem {
                Banner(message: "夸克网盘：" + problem) {
                    Button("重试") { Task { await model.quark.revalidate() } }
                    Button("登录") { model.presentLogin(for: .quark) }
                }
            }
            if !model.coordinator.removalProblems.isEmpty {
                Banner(message: model.coordinator.removalProblems.joined(separator: "\n")) {
                    Button("关闭") { model.coordinator.dismissRemovalProblems() }
                }
            }
        }
    }
}

/// 固定高度的提示条；点击摘要可滚动查看全文，长错误不改变主窗口的最小尺寸。
struct Banner<Actions: View>: View {
    let message: String
    var systemImage = "exclamationmark.triangle.fill"
    var iconColor: Color = .yellow
    @ViewBuilder let actions: Actions
    @State private var isShowingDetails = false

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
            Button { isShowingDetails = true } label: {
                Text(message)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("点击查看完整提示")
            .popover(isPresented: $isShowingDetails) {
                ScrollView {
                    Text(message)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(width: 420, height: 240)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            actions
                .fixedSize()
        }
        .padding(.horizontal)
        .frame(height: 64)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// 主工作区两侧底栏共用高度，使账号入口、选择摘要和传输统计居中对齐。
    func workspaceFooter() -> some View {
        frame(height: 44)
    }

    /// 让内容避开顶部或底部的实色操作栏；分隔线只占用该栏实际高度。
    func edgeBar(_ edge: VerticalEdge, @ViewBuilder content: () -> some View) -> some View {
        safeAreaInset(edge: edge, spacing: 0) {
            content().background {
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: edge == .top ? .bottom : .top) {
                        Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                    }
                    .clipped()
            }
        }
    }

    /// 退出登录前的确认。调用方在有未完成的任务时才把 `isPresented` 设为 true（见 `AppModel.requestLogOut`）。
    func logOutConfirmation(isPresented: Binding<Bool>) -> some View {
        modifier(LogOutConfirmation(isPresented: isPresented))
    }
}

private struct LogOutConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .confirmationDialog("退出登录？", isPresented: $isPresented) {
                Button("退出登录", role: .destructive) { model.logOut() }
            } message: {
                Text("重新登录后可继续任务。")
            }
    }
}
