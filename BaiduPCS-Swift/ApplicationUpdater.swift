import AppKit
import Observation
import Sparkle

/// 共享更新入口；安装前保存传输状态，活跃传输结束后由用户确认重启。
@Observable
final class ApplicationUpdater: NSObject, SPUUpdaterDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var availability: NSKeyValueObservation?
    @ObservationIgnored private var installHandler: (() -> Void)?
    private(set) var canCheck = false
    private(set) var hasPreparedUpdate = false
    var automaticChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticChecks }
    }

    init(model: AppModel) {
        self.model = model
        automaticChecks = true
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        automaticChecks = controller.updater.automaticallyChecksForUpdates
        availability = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let available = change.newValue ?? false
            Task { @MainActor [weak self] in self?.canCheck = available }
        }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// 空闲时交回 Sparkle，实际退出由 AppDelegate 等待引擎保存完成。
    func installPreparedUpdate() {
        guard let handler = installHandler, !model.hasActiveTransfers else { return }
        installHandler = nil
        hasPreparedUpdate = false
        model.isInstallingUpdate = true
        handler()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        self.installHandler = installHandler
        hasPreparedUpdate = true
        if model.hasActiveTransfers {
            let alert = NSAlert()
            alert.messageText = "等待传输完成"
            alert.informativeText = "更新已下载。传输完成后，可从 Ferry Plus 菜单安装并重新启动。"
            alert.addButton(withTitle: "好")
            if let window = NSApp.mainWindow { alert.beginSheetModal(for: window) }
            else { alert.runModal() }
        } else {
            installPreparedUpdate()
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        installHandler = nil
        hasPreparedUpdate = false
        model.isInstallingUpdate = false
    }
}
