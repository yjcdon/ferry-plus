import AppKit
import BaiduKit
import FerryCore
import SwiftUI

/// 设置窗口：传输、网盘、网络和账号四个标签页。
struct SettingsView: View {
    @AppStorage("settings.selectedTab.v1", store: AppPreferences.defaults) private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            TransferSettingsView()
                .tabItem { Label("传输", systemImage: "arrow.up.arrow.down.circle") }
                .tag(0)
            NetdiskSettingsView()
                .tabItem { Label("网盘", systemImage: "cloud") }
                .tag(1)
            NetworkSettingsView()
                .tabItem { Label("网络", systemImage: "network") }
                .tag(2)
            AccountSettingsView()
                .tabItem { Label("账号", systemImage: "person.crop.circle") }
                .tag(3)
        }
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        #if DEBUG
        .onAppear {
            if DemoData.isEnabled, let demoTab = DemoData.settingsTab { tab = demoTab }
        }
        #endif
    }
}

/// 下载目录、上传和下载预算以及剪贴板检测。
private struct TransferSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isChoosingDirectory = false

    /// “下载目录”菜单中的一项。
    private enum DirectoryChoice: Hashable {
        case downloads
        case chosen
        /// 打开面板选择目录，不改变当前选择。
        case other
    }

    private var directoryChoice: Binding<DirectoryChoice> {
        Binding {
            model.usesDefaultDownloadDirectory ? .downloads : .chosen
        } set: { choice in
            switch choice {
            case .downloads:
                // 同时清除无法访问的旧目录的 bookmark 和提示。
                if model.settings.downloadDirectoryBookmark != nil {
                    model.useDefaultDownloadDirectory()
                }
            case .chosen: break
            case .other: isChoosingDirectory = true
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                // 和 Safari 的“文件下载位置”相同：系统的“下载”目录、选择的目录和“其他…”。
                Picker("下载目录", selection: directoryChoice) {
                    FolderLabel(url: AppModel.defaultDownloadDirectory).tag(DirectoryChoice.downloads)
                    if !model.usesDefaultDownloadDirectory {
                        FolderLabel(url: model.downloadDirectory).tag(DirectoryChoice.chosen)
                    }
                    Divider()
                    Text("其他").tag(DirectoryChoice.other)
                }
                .help(model.downloadDirectory.path(percentEncoded: false))
                if let problem = model.downloadDirectoryProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                SettingsCountStepper(title: "同时下载文件数", value: $model.settings.maxConcurrentFiles,
                    range: model.settings.allowedConcurrentFiles, accessibilityName: "同时下载文件数")
                SettingsCountStepper(title: "同时上传任务数", value: $model.settings.maxConcurrentUploads,
                    range: FerrySettings.concurrentUploadsRange, accessibilityName: "同时上传任务数")
            }

            Section {
                TransferRateField(title: "上传限速", bytesPerSecond: $model.settings.uploadBytesPerSecond)
                TransferRateField(title: "下载限速", bytesPerSecond: $model.settings.downloadBytesPerSecond)
            } footer: {
                Text("0 表示不限速，1 KiB/s = 1024 字节/秒。")
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("高级") {
                    SettingsCountStepper(title: "每个上传文件的并发分片", value: $model.settings.uploadPartsPerFile,
                        range: FerrySettings.uploadPartsRange, accessibilityName: "每个上传文件的并发分片")
                    Text("适用于百度和夸克。增加分片并发可提高上传速度，也会增加内存使用。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("检测剪贴板中的分享链接", isOn: $model.settings.detectsCopiedLinks)
            } footer: {
                Text("复制分享链接后切换到 Ferry Plus，自动打开【添加链接】并填入链接和提取码。")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsFormSurface()
        .directoryPicker(isPresented: $isChoosingDirectory, directory: model.downloadDirectory,
                         onChoose: model.chooseDownloadDirectory)
    }
}

/// 以 KiB/s 编辑原始字节预算；限制乘法范围，避免输入极大整数导致溢出。
private struct TransferRateField: View {
    let title: String
    @Binding var bytesPerSecond: Int64

    private var kibibytesPerSecond: Binding<Int64> {
        Binding {
            max(0, bytesPerSecond) / 1024
        } set: { value in
            bytesPerSecond = min(max(0, value), Int64.max / 1024) * 1024
        }
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: kibibytesPerSecond, format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    .accessibilityLabel(title)
                Text("KiB/s").foregroundStyle(.secondary)
            }
        }
    }
}

/// 目录菜单中的一项：目录的显示名称和文件夹图标。
struct FolderLabel: View {
    let url: URL

    var body: some View {
        Label(FileManager.default.displayName(atPath: url.path(percentEncoded: false)), systemImage: "folder")
    }
}

/// 百度与夸克各自的转存、清理和单文件连接设置。
private struct NetdiskSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var transferFolder = ""
    @State private var quarkTransferFolder = ""

    /// 选择预设时填入它的两项。两项不等于任何预设时显示“自定义”。
    private var concurrencyPreset: Binding<ConcurrencyPreset?> {
        Binding {
            model.settings.concurrencyPreset
        } set: { preset in
            if let preset { model.settings.apply(preset) }
        }
    }

    @ViewBuilder private var concurrencyFooter: some View {
        switch model.settings.concurrencyPreset {
        case .regular:
            Text("普通账号使用单连接下载。会员预设也会调整同时下载文件数。")
                .foregroundStyle(.secondary)
        case .svip:
            Text("超级会员可使用多连接。总连接数上限为 \(FerrySettings.totalConnectionsLimit)，建议保持在 12 以内。")
                .foregroundStyle(.secondary)
        case nil:
            Text("多连接适用于百度超级会员，普通账号建议使用单连接。")
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("转存目录", text: $transferFolder, prompt: Text("/Ferry"))
                    .onSubmit(commitTransferFolders)
                Toggle("下载完成后清理转存文件", isOn: $model.settings.cleanupAfterDownload)
                Picker("网盘会员", selection: concurrencyPreset) {
                    Text("非超级会员").tag(ConcurrencyPreset?.some(.regular))
                    Text("超级会员").tag(ConcurrencyPreset?.some(.svip))
                    if model.settings.concurrencyPreset == nil {
                        Text("自定义").tag(ConcurrencyPreset?.none)
                    }
                }
                .help("会员预设会同时调整每个文件的连接数和同时下载文件数。")
                DisclosureGroup("高级") {
                    SettingsCountStepper(title: "每个文件的连接数", value: $model.settings.connectionsPerFile,
                        range: model.settings.allowedConnections, accessibilityName: "百度网盘每个文件的连接数")
                    concurrencyFooter
                        .font(.callout)
                }
            } header: {
                Text("百度网盘")
            } footer: {
                Text("每个分享任务使用独立子目录。清理范围为本任务创建的转存文件。")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("转存目录", text: $quarkTransferFolder, prompt: Text("/Ferry Plus"))
                    .onSubmit(commitTransferFolders)
                Toggle("下载完成后清理转存文件", isOn: $model.settings.quarkCleanupAfterDownload)
                DisclosureGroup("高级") {
                    SettingsCountStepper(title: "每个文件的连接数", value: $model.settings.quarkConnectionsPerFile,
                        range: model.settings.allowedConnections, accessibilityName: "夸克网盘每个文件的连接数")
                }
            } header: {
                Text("夸克网盘")
            } footer: {
                Text("每个分享任务使用独立子目录。清理范围为本任务创建的转存文件。")
                    .foregroundStyle(.secondary)
            }

        }
        .settingsFormSurface()
        .autocorrectionDisabled()
        .onAppear {
            transferFolder = model.settings.transferFolder
            quarkTransferFolder = model.settings.quarkTransferFolder
        }
        .onDisappear(perform: commitTransferFolders)
    }

    /// 提交两个网盘目录；空值恢复各自默认目录，其他值统一为绝对路径。
    private func commitTransferFolders() {
        transferFolder = normalizedFolder(transferFolder, defaultValue: FerrySettings().transferFolder)
        quarkTransferFolder = normalizedFolder(quarkTransferFolder, defaultValue: FerrySettings().quarkTransferFolder)
        model.settings.transferFolder = transferFolder
        model.settings.quarkTransferFolder = quarkTransferFolder
    }

    /// 目录输入在设置边界统一去除首尾空白并整理路径。
    private func normalizedFolder(_ input: String, defaultValue: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultValue : RemotePath.normalized(trimmed)
    }
}

/// 代理。
private struct NetworkSettingsView: View {
    @Environment(AppModel.self) private var model
    /// 文本框的草稿。按回车、焦点离开全部文本框、切换标签页或关闭设置时一起提交，输入过程中不换代理，不打断下载。
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case host, port, username, password
    }

    /// 切换模式时同时提交草稿，所以只换一次代理。
    private var mode: Binding<ProxySettings.Mode> {
        Binding {
            model.settings.proxy.mode
        } set: { mode in
            commit(mode: mode)
        }
    }

    /// 选了 SOCKS5 但还什么都没填。这时不显示警告。
    private var isBlank: Bool {
        let proxy = model.settings.proxy
        return proxy.mode == .socks5 && proxy.host.isEmpty && proxy.port == nil && proxy.username.isEmpty
            && model.proxyPassword.isEmpty
    }

    var body: some View {
        Form {
            Section {
                Picker("代理", selection: mode) {
                    Text("使用系统设置").tag(ProxySettings.Mode.system)
                    Text("SOCKS5").tag(ProxySettings.Mode.socks5)
                }
                if model.settings.proxy.mode == .socks5 {
                    TextField("服务器", text: $host, prompt: Text("127.0.0.1"))
                        .focused($focusedField, equals: .host)
                    TextField("端口", text: $port, prompt: Text("1080"))
                        .focused($focusedField, equals: .port)
                    TextField("用户名", text: $username, prompt: Text("可选"))
                        .focused($focusedField, equals: .username)
                    SecureField("密码", text: $password, prompt: Text("可选"))
                        .focused($focusedField, equals: .password)
                }
                if !isBlank, let problem = model.proxyProblem {
                    Label("\(problem)当前使用系统代理设置。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let problem = model.proxyPasswordProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("网盘请求和文件下载使用这个代理。")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsFormSurface()
        .autocorrectionDisabled()
        .onSubmit { commit() }
        // 在文本框之间切换时不提交：例如填了用户名还没填密码时，设置不完整，会先退回系统设置再换回代理。
        .onChange(of: focusedField) { _, field in
            if field == nil { commit() }
        }
        .onAppear {
            let proxy = model.settings.proxy
            host = proxy.host
            port = proxy.port.map(String.init) ?? ""
            username = proxy.username
            password = model.proxyPassword
        }
        .onDisappear { commit() }
    }

    /// 端口不是数字时提交为未填写，由 `proxyProblem` 提示。
    private func commit(mode: ProxySettings.Mode? = nil) {
        var proxy = model.settings.proxy
        if let mode { proxy.mode = mode }
        proxy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        proxy.port = Int(port.trimmingCharacters(in: .whitespacesAndNewlines))
        proxy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        model.setProxy(proxy, password: password)
        host = proxy.host
        port = proxy.port.map(String.init) ?? ""
        username = proxy.username
    }
}

/// 用户名、登录状态和登录操作。
private struct AccountSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var isConfirmingLogOut = false
    @State private var quarkLogoutError: String?

    var body: some View {
        Form {
            Section {
                if let account = model.account {
                    LabeledContent("账号名称", value: account.username.isEmpty ? "百度账号" : account.username)
                    LabeledContent("状态") {
                        if model.isLoginExpired {
                            Label("登录已失效", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } else {
                            Text("已登录")
                        }
                    }
                    HStack {
                        Spacer()
                        if model.isLoginExpired {
                            Button("重新登录", action: showLogin)
                        }
                        Button("退出登录") { isConfirmingLogOut = model.requestLogOut() }
                    }
                } else {
                    LabeledContent("状态", value: "待登录")
                    HStack {
                        Spacer()
                        Button("登录", action: showLogin)
                    }
                }
            } header: {
                Text("百度网盘")
            }
            Section("夸克网盘") {
                if let summary = model.quark.summary {
                    LabeledContent("账号名称", value: summary.name)
                }
                LabeledContent("状态") {
                    if case .expired = model.quark.state {
                        Label(model.quark.state.title, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text(model.quark.state.title)
                    }
                }
                if let problem = model.quark.problem {
                    Text(problem).foregroundStyle(.orange)
                }
                if let quarkLogoutError {
                    Text(quarkLogoutError).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    if model.quark.account == nil {
                        Button("登录") { openWindow(id: QuarkLoginView.windowID) }
                    } else {
                        if case .expired = model.quark.state {
                            Button("重新登录") { openWindow(id: QuarkLoginView.windowID) }
                        } else if case .problem = model.quark.state {
                            Button("重试") { Task { await model.quark.revalidate() } }
                        }
                        Button("退出登录", action: logOutQuark)
                    }
                }
            }
        }
        .settingsFormSurface()
        .logOutConfirmation(isPresented: $isConfirmingLogOut)
    }

    private func showLogin() {
        openWindow(id: ContentView.windowID)
        model.presentLogin()
    }

    /// 退出夸克后保留百度会话；凭据删除失败时在对应账号区域说明原因。
    private func logOutQuark() {
        Task {
            do {
                try await model.quark.logOut()
                quarkLogoutError = nil
            } catch { quarkLogoutError = error.localizedDescription }
        }
    }
}

/// 设置中的整数预算沿用同一原生步进布局、范围及业务辅助属性。
private struct SettingsCountStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let accessibilityName: String

    var body: some View {
        Stepper(value: $value, in: range) {
            LabeledContent(title, value: "\(value)")
        }
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(Text("\(value)"))
    }
}

private extension View {
    /// 四类设置共用系统分组表单与实色页面表面。
    func settingsFormSurface() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
