import Foundation

/// 正式界面使用系统偏好，Debug 演示的业务设置与浏览偏好保存在独立域。
enum AppPreferences {
    static let defaults: UserDefaults = {
        #if DEBUG
        if DemoData.isEnabled { return DemoData.preferences }
        #endif
        return .standard
    }()

    /// 场景恢复沿用原键；演示窗口的详情状态独立保存。
    static func sceneKey(_ key: String) -> String {
        #if DEBUG
        if DemoData.isEnabled { return "demo." + key }
        #endif
        return key
    }
}
