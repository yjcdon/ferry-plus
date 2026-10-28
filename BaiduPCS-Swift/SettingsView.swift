import BaiduKit
import FerryCore
import SwiftUI

/// 设置窗口：传输、网盘、网络和账号四个标签页。
struct SettingsView: View {
    @State private var tab = 0

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
                    Text("其他…").tag(DirectoryChoice.other)
                }
                .help(model.downloadDirectory.path(percentEncoded: false))
                if let problem = model.downloadDirectoryProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Stepper(value: $model.settings.maxConcurrentFiles, in: model.settings.allowedConcurrentFiles) {
                    LabeledContent("同时下载文件数", value: "\(model.settings.maxConcurrentFiles)")
                }
                Stepper(value: $model.settings.maxConcurrentUploads, in: FerrySettings.concurrentUploadsRange) {
                    LabeledContent("同时上传任务数", value: "\(model.settings.maxConcurrentUploads)")
                }
                Stepper(value: $model.settings.uploadPartsPerFile, in: FerrySettings.uploadPartsRange) {
                    LabeledContent("每个上传文件的并发分片", value: "\(model.settings.uploadPartsPerFile)")
                }
            } footer: {
                Text("并发设置适用于百度和夸克。提高分片并发会增加内存占用，默认 1 路。")
                    .foregroundStyle(.secondary)
            }

            Section {
                TransferRateField(title: "上传限速", bytesPerSecond: $model.settings.uploadBytesPerSecond)
                TransferRateField(title: "下载限速", bytesPerSecond: $model.settings.downloadBytesPerSecond)
            } footer: {
                Text("0 表示不限速。1 KiB/s = 1024 字节/秒，下载限速也适用于上传后的内容校验。")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("检测剪贴板中的分享链接", isOn: $model.settings.detectsCopiedLinks)
            } footer: {
                Text("复制分享链接后切换到 Ferry Plus，自动打开“添加链接”并填入链接和提取码。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
            Text("非超级会员（包括普通会员）同时使用多个连接会被百度限速，所以两项都是 1。")
                .foregroundStyle(.secondary)
        case .svip:
            Text("超级会员下载不限速。两项相乘最多为 \(FerrySettings.totalConnectionsLimit)，建议不超过 12。")
                .foregroundStyle(.secondary)
        case nil:
            Label("只有超级会员可以同时使用多个连接。其他账号会被百度限速，限速可能持续数小时到数天，并影响这个账号的所有客户端。",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("转存目录", text: $transferFolder, prompt: Text("/Ferry"))
                    .onSubmit(commitTransferFolders)
                Toggle("内容校验通过后清理转存文件", isOn: $model.settings.cleanupAfterDownload)
                Picker("网盘会员", selection: concurrencyPreset) {
                    Text("非超级会员").tag(ConcurrencyPreset?.some(.regular))
                    Text("超级会员").tag(ConcurrencyPreset?.some(.svip))
                    if model.settings.concurrencyPreset == nil {
                        Text("自定义").tag(ConcurrencyPreset?.none)
                    }
                }
                Stepper(value: $model.settings.connectionsPerFile, in: model.settings.allowedConnections) {
                    LabeledContent("每个文件的连接数", value: "\(model.settings.connectionsPerFile)")
                }
            } header: {
                Text("百度网盘")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("每个分享任务转存到指定目录的独立子目录。会员预设会同时调整通用的同时下载文件数。")
                        .foregroundStyle(.secondary)
                    concurrencyFooter
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                TextField("转存目录", text: $quarkTransferFolder, prompt: Text("/Ferry Plus"))
                    .onSubmit(commitTransferFolders)
                Toggle("内容校验通过后清理转存文件", isOn: $model.settings.quarkCleanupAfterDownload)
                Stepper(value: $model.settings.quarkConnectionsPerFile, in: model.settings.allowedConnections) {
                    LabeledContent("每个文件的连接数", value: "\(model.settings.quarkConnectionsPerFile)")
                }
            } header: {
                Text("夸克网盘")
            } footer: {
                Text("每个分享任务转存到指定目录的独立子目录。仅清理本任务创建的转存文件，直接从网盘下载的源文件会保留。")
                    .foregroundStyle(.secondary)
            }

            IntegrityRecordSettingsSection()
        }
        .formStyle(.grouped)
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

/// 校验依据独立于任务保存；清理只处理用户确认的有限快照，结果如实展示部分失败。
private struct IntegrityRecordSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var inventory: IntegrityStore.Inventory?
    @State private var pendingInventory: IntegrityStore.Inventory?
    @State private var isLoading = false
    @State private var isCleaning = false
    @State private var showsConfirmation = false
    @State private var problem: String?
    @State private var resultSummary: String?
    @State private var resultFailures: [IntegrityStore.CleanupFailure] = []

    private var failures: [IntegrityStore.CleanupFailure] {
        resultFailures.isEmpty ? (inventory?.failures ?? []) : resultFailures
    }

    var body: some View {
        Section {
            LabeledContent("已保存校验记录") {
                if isLoading { ProgressView().controlSize(.small) }
                else if let inventory { Text("\(inventory.totalCount) 条") }
                else { Text("读取失败").foregroundStyle(.secondary) }
            }
            HStack {
                Button("清理校验记录…", role: .destructive) { prepareConfirmation() }
                    .disabled(isLoading || isCleaning || (inventory?.recordIDs.isEmpty ?? true))
                Spacer()
                if isCleaning { ProgressView().controlSize(.small) }
            }
            if let resultSummary {
                Text(resultSummary).font(.caption).foregroundStyle(.secondary)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !failures.isEmpty {
                DisclosureGroup("\(failures.count) 条记录未清理，查看原因") {
                    ScrollView {
                        Text(failures.map { "\($0.fileName)：\($0.reason)" }.joined(separator: "\n"))
                            .font(.caption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                }
            }
        } header: {
            Text("内容校验")
        } footer: {
            Text("清理后，将无法再使用这些记录核对文件。")
                .foregroundStyle(.secondary)
        }
        .task(id: model.integrityRecordsRevision) { await reloadInventory() }
        .alert("清理校验记录？", isPresented: $showsConfirmation) {
            Button("取消", role: .cancel) { pendingInventory = nil }
            Button("移到废纸篓", role: .destructive) { cleanConfirmedRecords() }
        } message: {
            Text("将 \(pendingInventory?.recordIDs.count ?? 0) 条校验记录移到废纸篓？任务和文件会保留。")
        }
    }

    /// 重新捕获清理范围，确认窗口打开后产生的新记录不加入本轮。
    private func prepareConfirmation() {
        guard !isLoading, !isCleaning else { return }
        Task {
            await reloadInventory()
            guard let inventory, !inventory.recordIDs.isEmpty else { return }
            pendingInventory = inventory
            showsConfirmation = true
        }
    }

    /// 读取失败保留原文件；只有明确有效的 ID 才会出现在可确认清理列表。
    private func reloadInventory() async {
        isLoading = true
        defer { isLoading = false }
        do {
            inventory = try await model.integrityStore.inventory()
            problem = nil
        } catch {
            inventory = nil
            problem = error.localizedDescription
        }
    }

    /// 确认后逐项移入废纸篓；部分成功也通知详情刷新，失败文件及原因完整保留。
    private func cleanConfirmedRecords() {
        guard !isCleaning, let snapshot = pendingInventory else { return }
        pendingInventory = nil; isCleaning = true
        Task {
            let result = await model.integrityStore.moveToTrash(ids: snapshot.recordIDs)
            resultFailures = snapshot.failures + result.failures
            resultSummary = "已清理 \(result.deletedIDs.count) 条，保留 \(resultFailures.count) 条。"
            if !result.deletedIDs.isEmpty { model.integrityRecordsRevision += 1 }
            await reloadInventory()
            isCleaning = false
        }
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
                    Label("\(problem)Ferry 暂时使用系统设置。", systemImage: "exclamationmark.triangle.fill")
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
        .formStyle(.grouped)
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
                    LabeledContent("用户名", value: account.username.isEmpty ? "未知" : account.username)
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
                            Button("重新登录…", action: showLogin)
                        }
                        Button("退出登录") { isConfirmingLogOut = model.requestLogOut() }
                    }
                } else {
                    LabeledContent("状态", value: "未登录")
                    HStack {
                        Spacer()
                        Button("登录…", action: showLogin)
                    }
                }
            } header: {
                Text("百度网盘")
            }
            Section("夸克网盘") {
                if let summary = model.quark.summary {
                    LabeledContent("用户名", value: summary.name)
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
                        Button("登录…") { openWindow(id: QuarkLoginView.windowID) }
                    } else {
                        if case .expired = model.quark.state {
                            Button("重新登录…") { openWindow(id: QuarkLoginView.windowID) }
                        } else if case .problem = model.quark.state {
                            Button("重试") { Task { await model.quark.revalidate() } }
                        }
                        Button("退出登录", action: logOutQuark)
                    }
                }
            }
        }
        .formStyle(.grouped)
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
