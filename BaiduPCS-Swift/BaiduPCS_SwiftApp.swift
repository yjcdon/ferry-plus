import FerryCore
import SwiftUI

@main
struct FerryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Ferry Plus", id: ContentView.windowID) {
            ContentView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            SidebarCommands()
            FerryCommands(model: appDelegate.model)
        }

        // 百度的登录页可能比主窗口大，所以登录用单独的窗口，不用 sheet。
        Window("登录百度网盘", id: LoginView.windowID) {
            LoginView()
                .environment(appDelegate.model)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Window("登录夸克网盘", id: QuarkLoginView.windowID) {
            QuarkLoginView()
                .environment(appDelegate.model)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}

private struct FerryCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.transferSelection) private var selection
    @FocusedValue(\.focusTaskSearch) private var focusTaskSearch
    @FocusedBinding(\.transferInspectorPresented) private var inspectorPresented: Bool?

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(inspectorPresented == true ? "隐藏详情" : "显示详情") {
                inspectorPresented?.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(inspectorPresented == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("搜索任务") { focusTaskSearch?() }
                .keyboardShortcut("f")
                .disabled(focusTaskSearch == nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("添加链接…") {
                openWindow(id: ContentView.windowID)
                model.presentAddLink()
            }
            .keyboardShortcut("n")
            Button("从我的网盘下载…") {
                openWindow(id: ContentView.windowID)
                model.requestNetdiskDownload()
            }
            Button("上传文件…") {
                let provider = selection?.providerFilter
                openWindow(id: ContentView.windowID)
                model.presentUpload(provider: provider)
            }
            .keyboardShortcut("u")
        }
        CommandMenu("任务") {
            if let selection {
                TransferActionsMenu(scope: selection, showsUnavailable: true)
                    .environment(model)
            } else {
                Button("未选择传输任务") {}.disabled(true)
            }
            Divider()
            let visible = selection?.visibleItems ?? []
            let pausable = visible.filter { TransferAction.pause.allows($0, model: model) }
            let resumable = visible.filter { TransferAction.resume.allows($0, model: model) }
            Button("暂停当前列表") { selection?.onAction(.pause, pausable.map(\.id)) }
                .disabled(selection?.isBusy != false || pausable.isEmpty)
            Button("继续当前列表") { selection?.onAction(.resume, resumable.map(\.id)) }
                .disabled(selection?.isBusy != false || resumable.isEmpty)
        }
        CommandMenu("账号") {
            AccountCommandsView()
                .environment(model)
        }
    }
}

/// 菜单栏与主窗口读取同一会话；仅在未登录或登录失效时提供登录入口。
private struct AccountCommandsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("百度网盘 · \(model.account.map { $0.username.isEmpty ? "百度账号" : $0.username } ?? "未登录")")
        if model.account == nil || model.isLoginExpired {
            Button(model.isLoginExpired ? "重新登录百度网盘…" : "登录百度网盘…") {
                openWindow(id: ContentView.windowID)
                model.presentLogin()
            }
        }
        if model.account != nil {
            Button("退出登录") {
                if model.requestLogOut() {
                    openWindow(id: ContentView.windowID)
                    model.isConfirmingMenuLogOut = true
                }
            }
        }
        Divider()
        Text("夸克网盘 · \(model.quark.summary?.name ?? "未登录")")
        QuarkAccountControls()
    }
}
