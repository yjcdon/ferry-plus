import AppKit
import FerryCore
import Observation

/// 主窗口的直接上传入口：选择或投放时固定目标，入队后由后台任务负责扫描和上传。
@MainActor @Observable
final class DirectUploadPresenter {
    private(set) var isBusy = false
    @ObservationIgnored weak var parentWindow: NSWindow?
    @ObservationIgnored private var panel: NSOpenPanel?
    @ObservationIgnored private var submission: Task<Void, Never>?

    private struct UploadEntryError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 空文件列表打开系统选择器；已有投放文件直接入队，完成回调区分取消与成功。
    func start(context: DirectoryContext, files: [URL], model: AppModel,
               completion: @escaping @MainActor (Result<Bool, Error>) -> Void) {
        guard !isBusy else { return }
        isBusy = true
        if !files.isEmpty {
            submit(files, context: context, model: model, completion: completion)
            return
        }
        guard let parentWindow else {
            isBusy = false
            completion(.failure(UploadEntryError(message: "请重新打开上传窗口。")))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "上传"
        self.panel = panel
        panel.beginSheetModal(for: parentWindow) { [weak self, weak panel] response in
            guard let self else { return }
            let files = panel?.urls
            self.panel = nil
            guard response == .OK, let files, !files.isEmpty else {
                self.isBusy = false
                completion(.success(false))
                return
            }
            self.submit(files, context: context, model: model, completion: completion)
        }
    }

    /// 窗口离开时关闭系统选择器；已经接受的上传继续完成入队。
    func cancelPicker() {
        panel?.cancel(nil)
    }

    /// 本地文件权限保持到书签和任务保存完成；账号或客户端已变化时拒绝提交旧目标。
    private func submit(_ files: [URL], context: DirectoryContext, model: AppModel,
                        completion: @escaping @MainActor (Result<Bool, Error>) -> Void) {
        submission = Task {
            var authorized: [URL] = []
            defer {
                authorized.forEach { $0.stopAccessingSecurityScopedResource() }
                isBusy = false
                submission = nil
            }
            do {
                guard files.allSatisfy(\.isFileURL) else {
                    throw UploadEntryError(message: "请选择本地文件或文件夹。")
                }
                guard context.reference.provider == context.account.provider,
                      model.accountKey(for: context.provider) == context.account,
                      model.coordinator.netdisks[context.provider].map(ObjectIdentifier.init) == context.session else {
                    throw UploadEntryError(message: "登录状态已变化，请重新选择上传位置。")
                }
                var seen = Set<URL>()
                let files = files.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
                for file in files where file.startAccessingSecurityScopedResource() { authorized.append(file) }
                try await model.addUpload(files: files, account: context.account,
                                          destination: context.reference, conflictPolicy: .keepBoth)
                completion(.success(true))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
