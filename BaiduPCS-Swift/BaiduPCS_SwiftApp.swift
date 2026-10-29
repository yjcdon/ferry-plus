import AppKit
import FerryCore
import SwiftUI

@main
struct FerryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Ferry Plus", id: ContentView.windowID) {
            ContentView()
                .environment(appDelegate.model)
                .solidWindowSurface()
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 960, height: 640)
        .commands {
            SidebarCommands()
            FerryCommands(model: appDelegate.model)
        }

        // 百度的登录页可能比主窗口大，所以登录用单独的窗口，不用 sheet。
        Window("登录百度网盘", id: LoginView.windowID) {
            LoginView()
                .environment(appDelegate.model)
                .solidWindowSurface()
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Window("登录夸克网盘", id: QuarkLoginView.windowID) {
            QuarkLoginView()
                .environment(appDelegate.model)
                .solidWindowSurface()
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(appDelegate.model)
                .solidWindowSurface()
        }
    }
}

private struct FerryCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.transferSelection) private var selection
    @FocusedValue(\.focusTaskSearch) private var focusTaskSearch
    @FocusedValue(\.workspaceIsFiles) private var workspaceIsFiles
    @FocusedValue(\.selectWorkspaceItems) private var selectWorkspaceItems
    @FocusedBinding(\.transferInspectorPresented) private var inspectorPresented: Bool?

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            editingButton("剪切", action: #selector(NSText.cut(_:))).keyboardShortcut("x")
            editingButton("拷贝", action: #selector(NSText.copy(_:))).keyboardShortcut("c")
            editingButton("粘贴", action: #selector(NSText.paste(_:))).keyboardShortcut("v")
            editingButton("粘贴并匹配样式", action: #selector(NSTextView.pasteAsPlainText(_:)))
                .keyboardShortcut("v", modifiers: [.command, .option, .shift])
            editingButton("删除", action: #selector(NSText.delete(_:)))
            Button("全选", action: selectAll)
                .keyboardShortcut("a")
                .disabled(selectWorkspaceItems == nil && NSApp.keyWindow == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(inspectorPresented == true ? "隐藏详情" : "显示详情") {
                inspectorPresented?.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(inspectorPresented == nil)
        }
        CommandGroup(after: .textEditing) {
            Button(workspaceIsFiles == true ? "搜索当前目录" : "搜索任务") { focusTaskSearch?() }
                .keyboardShortcut("f")
                .disabled(focusTaskSearch == nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("添加链接") {
                openWindow(id: ContentView.windowID)
                model.presentAddLink()
            }
            .keyboardShortcut("n")
            Button("浏览网盘") {
                openWindow(id: ContentView.windowID)
                model.requestWorkspace(.browse(nil))
            }
            Button("上传文件") {
                openWindow(id: ContentView.windowID)
                model.requestWorkspace(.upload([]))
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
    /// 剪贴板行为交给执行时的原生响应者，不缓存会随文本选区变化的可用性。
    private func editingButton(_ title: String, action: Selector) -> some View {
        Button(title) { NSApp.sendAction(action, to: nil, from: nil) }
    }

    /// 文本编辑优先使用原生全选；列表全选仅使用主窗口当前提供的可见范围。
    private func selectAll() {
        if let text = NSApp.keyWindow?.firstResponder as? NSText { text.selectAll(nil) }
        else if let field = NSApp.keyWindow?.firstResponder as? NSTextField { field.selectText(nil) }
        else if let selectWorkspaceItems { selectWorkspaceItems() }
        else { NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil) }
    }
}

/// 菜单栏与主窗口读取同一会话；仅在未登录或登录失效时提供登录入口。
private struct AccountCommandsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("百度网盘 · \(model.account.map { $0.username.isEmpty ? "百度账号" : $0.username } ?? "待登录")")
        if model.account == nil || model.isLoginExpired {
            Button(model.isLoginExpired ? "重新登录百度网盘" : "登录百度网盘") {
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
        Text("夸克网盘 · \(model.quark.summary?.name ?? "待登录")")
        QuarkAccountControls()
    }
}
