import AppKit

/// 只把系统睡眠／唤醒事件交给 AppModel 的串行收尾，不修改任务的手动暂停状态。
@MainActor
final class TransferLifecycle {
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        for (notification, sleeping) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            observers.append(center.addObserver(forName: notification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange(sleeping) }
            })
        }
    }

    /// 退出时解除观察，避免系统事件在 shutdown 后继续排入恢复操作。
    func close() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    isolated deinit {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
    }
}
