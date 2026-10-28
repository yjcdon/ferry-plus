import AppKit
import FerryCore
import SwiftUI

/// 新任务的“下载到”菜单。默认是设置中的下载目录。用“其他…”选择的目录只用于这个任务，不修改设置。
///
/// 选择目录时立即创建 bookmark。创建失败时不选中这个目录，由调用方显示 `error`。
struct DownloadFolderPicker: View {
    /// nil 表示设置中的下载目录。
    @Binding var selection: DownloadFolder?
    @Binding var error: String?
    @Environment(AppModel.self) private var model
    /// 用“其他…”选择的目录。
    @State private var chosenFolders: [DownloadFolder] = []
    @State private var isChoosingFolder = false

    /// 菜单中的一项。
    private enum Destination: Hashable {
        /// 设置中的下载目录。
        case settings
        case chosen(DownloadFolder)
        /// “其他…”：打开面板选择目录，不改变当前选择。
        case other
    }

    var body: some View {
        Picker("下载到", selection: destination) {
            FolderLabel(url: model.currentFolder.url).tag(Destination.settings)
            ForEach(chosenFolders, id: \.self) { folder in
                FolderLabel(url: folder.url).tag(Destination.chosen(folder))
            }
            Divider()
            Text("其他…").tag(Destination.other)
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help((selection ?? model.currentFolder).url.path(percentEncoded: false))
        .directoryPicker(isPresented: $isChoosingFolder, directory: (selection ?? model.currentFolder).url,
                         onChoose: chooseFolder)
    }

    private var destination: Binding<Destination> {
        Binding {
            selection.map(Destination.chosen) ?? .settings
        } set: { destination in
            switch destination {
            case .settings: selection = nil
            case .chosen(let folder): selection = folder
            case .other: isChoosingFolder = true
            }
        }
    }

    /// 选择的目录加入菜单并选中。它和菜单中已有的目录是同一位置时，选中已有的那一项。
    private func chooseFolder(_ url: URL) {
        error = nil
        func isSameLocation(_ folder: DownloadFolder) -> Bool {
            folder.url.standardizedFileURL.path == url.standardizedFileURL.path
        }
        if isSameLocation(model.currentFolder) {
            selection = nil
        } else if let existing = chosenFolders.first(where: isSameLocation) {
            selection = existing
        } else {
            do {
                let folder = try model.makeDownloadFolder(for: url)
                chosenFolders.append(folder)
                selection = folder
            } catch {
                self.error = "无法取得“\(url.lastPathComponent)”的访问权限：\(error.localizedDescription)"
            }
        }
    }
}

extension View {
    /// Mac 目录选择明确使用 NSOpenPanel 的目录模式，不按文件内容类型过滤目录。
    func directoryPicker(isPresented: Binding<Bool>, directory: URL,
                         onChoose: @escaping (URL) -> Void) -> some View {
        modifier(DirectoryPicker(isPresented: isPresented, directory: directory, onChoose: onChoose))
    }
}

/// 任务和全局设置共用目录面板；取消不改变原选择，确认后交给调用方创建 bookmark。
private struct DirectoryPicker: ViewModifier {
    @Binding var isPresented: Bool
    let directory: URL
    let onChoose: (URL) -> Void
    @State private var panel: NSOpenPanel?

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, presented in
                if presented { present() } else { panel?.cancel(nil) }
            }
            .onDisappear {
                panel?.cancel(nil)
                panel = nil
                isPresented = false
            }
    }

    /// 仅接受用户确认的一个目录；NSOpenPanel 保证 URL 来自本次目录选择。
    private func present() {
        guard panel == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.prompt = "选择"
        self.panel = panel
        panel.begin { [weak panel] response in
            let selected = response == .OK ? panel?.url : nil
            self.panel = nil
            isPresented = false
            if let selected { onChoose(selected) }
        }
    }
}
