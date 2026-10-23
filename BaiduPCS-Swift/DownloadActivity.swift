import Foundation

/// 实际下载期间阻止系统因闲置而休眠；暂停或下载结束后立即释放。
@MainActor
final class DownloadActivity {
    private var token: (any NSObjectProtocol)?

    /// 多个下载共用一次系统活动声明；重复设置相同状态不会增加持有数量。
    func setActive(_ active: Bool) {
        if active {
            guard token == nil else { return }
            token = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "Ferry Plus 正在下载文件"
            )
        } else if let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }

    /// 应用关闭时同步释放；不等待下载状态回调。
    func close() {
        setActive(false)
    }

    isolated deinit {
        if let token { ProcessInfo.processInfo.endActivity(token) }
    }
}
