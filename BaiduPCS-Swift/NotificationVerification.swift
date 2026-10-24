#if DEBUG
import Foundation
import FerryCore
import UserNotifications

/// 只查询当前签名应用的系统通知状态；没有完整过滤条件时不读取任何已送达通知。
enum NotificationVerification {
    struct Report: Encodable {
        var state: String
        var authorization: String?
        var alerts: String?
        var notificationCenter: String?
        var alertStyle: String?
        var matchingCount: Int?
        var titleMatches: Bool?
        var providerMatches: Bool?
        var unverifiedNotice: Bool?
    }

    private struct Filter {
        let jobID: UUID
        let since: Date
        let provider: Provider
    }

    /// 只输出本次指定任务的匹配数量和内容校验布尔值，不输出正文、文件名或旧通知。
    static func inspect(arguments: [String]) async -> Report {
        let filter: Filter?
        do { filter = try parse(arguments) }
        catch { return Report(state: "invalid_arguments") }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        var report = Report(state: filter == nil ? "permission_only" : "inspected")
        switch settings.authorizationStatus {
        case .notDetermined: report.authorization = "not_determined"
        case .denied: report.authorization = "denied"
        case .authorized: report.authorization = "authorized"
        case .provisional: report.authorization = "provisional"
        @unknown default: report.authorization = "unknown"
        }
        report.alerts = setting(settings.alertSetting)
        report.notificationCenter = setting(settings.notificationCenterSetting)
        switch settings.alertStyle {
        case .none: report.alertStyle = "none"
        case .banner: report.alertStyle = "banner"
        case .alert: report.alertStyle = "alert"
        @unknown default: report.alertStyle = "unknown"
        }
        guard let filter else { return report }
        let delivered = await center.deliveredNotifications()
        let matches = delivered.filter {
            $0.request.identifier == filter.jobID.uuidString && $0.date >= filter.since
        }
        report.matchingCount = matches.count
        report.titleMatches = !matches.isEmpty && matches.allSatisfy {
            ["下载完成", "下载完成 · 未验证"].contains($0.request.content.title)
        }
        report.unverifiedNotice = !matches.isEmpty && matches.allSatisfy {
            $0.request.content.title == "下载完成 · 未验证" &&
            $0.request.content.body.hasSuffix(" · 未验证源文件内容")
        }
        let prefix = filter.provider.title + " · "
        report.providerMatches = !matches.isEmpty && matches.allSatisfy { $0.request.content.body.hasPrefix(prefix) }
        return report
    }

    /// 各值先按类型校验；重复、未知或无值参数明确失败。过滤条件缺一项便只返回权限。
    private static func parse(_ arguments: [String]) throws -> Filter? {
        var seen = Set<String>()
        var jobID: UUID?
        var since: Date?
        var provider: Provider?
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard seen.insert(option).inserted else { throw InvalidArguments() }
            index += 1
            if option == "--inspect-notifications" { continue }
            guard ["--notification-job", "--notification-since", "--notification-provider"].contains(option),
                  index < arguments.count else { throw InvalidArguments() }
            let value = arguments[index]
            index += 1
            switch option {
            case "--notification-job":
                guard let parsed = UUID(uuidString: value) else { throw InvalidArguments() }
                jobID = parsed
            case "--notification-since":
                guard let parsed = Double(value), parsed.isFinite, parsed >= 0,
                      parsed <= Date.distantFuture.timeIntervalSince1970 else { throw InvalidArguments() }
                since = Date(timeIntervalSince1970: parsed)
            case "--notification-provider":
                guard let parsed = Provider(rawValue: value) else { throw InvalidArguments() }
                provider = parsed
            default: throw InvalidArguments()
            }
        }
        guard seen.contains("--inspect-notifications") else { throw InvalidArguments() }
        guard let jobID, let since, let provider else { return nil }
        return Filter(jobID: jobID, since: since, provider: provider)
    }

    private static func setting(_ value: UNNotificationSetting) -> String {
        switch value {
        case .notSupported: "not_supported"
        case .disabled: "disabled"
        case .enabled: "enabled"
        @unknown default: "unknown"
        }
    }

    private struct InvalidArguments: Error {}
}
#endif
