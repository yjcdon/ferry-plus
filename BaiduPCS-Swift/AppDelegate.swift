import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    #if DEBUG
    private var naturalExpirySignals: [any DispatchSourceSignal] = []
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--inspect-notifications") {
            NSApp.setActivationPolicy(.prohibited)
            NSApp.windows.forEach { $0.orderOut(nil) }
            Task {
                let report = await NotificationVerification.inspect(arguments: Array(ProcessInfo.processInfo.arguments.dropFirst()))
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    FileHandle.standardOutput.write(try encoder.encode(report) + Data([10]))
                    exit(report.state == "invalid_arguments" ? 1 : 0)
                } catch {
                    FileHandle.standardError.write(Data("无法生成通知状态报告。\n".utf8))
                    exit(1)
                }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-drive-natural-expiry") {
            NSApp.setActivationPolicy(.prohibited)
            NSApp.windows.forEach { $0.orderOut(nil) }
            let verification = Task {
                let smoke = ProcessInfo.processInfo.arguments.contains("--natural-expiry-smoke")
                let report = await model.verifyNaturalExpiry(smoke: smoke) { report in
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    if let data = try? encoder.encode(report) { FileHandle.standardOutput.write(data + Data([10])) }
                }
                await model.shutdown()
                naturalExpirySignals.forEach { $0.cancel() }
                naturalExpirySignals.removeAll()
                exit(!report.results.isEmpty && report.results.allSatisfy { $0.state == "verified" } ? 0 : 1)
            }
            for value in [SIGTERM, SIGINT] {
                signal(value, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
                source.setEventHandler { verification.cancel() }
                source.resume()
                naturalExpirySignals.append(source)
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-drive-resume") {
            NSApp.setActivationPolicy(.prohibited)
            NSApp.windows.forEach { $0.orderOut(nil) }
            Task {
                let report = await model.verifyBoundedResume()
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    FileHandle.standardOutput.write(try encoder.encode(report) + Data([10]))
                    await model.shutdown()
                    exit(report.results.allSatisfy { $0.state == "verified" } ? 0 : 1)
                } catch {
                    FileHandle.standardError.write(Data("无法生成有界续传验证结果。\n".utf8))
                    await model.shutdown()
                    exit(1)
                }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-quark-capacity") {
            NSApp.setActivationPolicy(.prohibited)
            NSApp.windows.forEach { $0.orderOut(nil) }
            Task {
                do {
                    let report = try await model.quark.capacityVerificationReport()
                    FileHandle.standardOutput.write(report + Data([10]))
                    exit(0)
                } catch {
                    let report = ["provider": "quark", "problem": error.localizedDescription]
                    do {
                        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                        FileHandle.standardOutput.write(data + Data([10]))
                    } catch {
                        FileHandle.standardError.write(Data("无法生成夸克容量验证报告。\n".utf8))
                    }
                    exit(1)
                }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-drive-interfaces") {
            NSApp.setActivationPolicy(.prohibited)
            NSApp.windows.forEach { $0.orderOut(nil) }
            Task {
                let report = await model.verifyInterfaces()
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    FileHandle.standardOutput.write(try encoder.encode(report) + Data([10]))
                    await model.shutdown()
                    exit(report.results.allSatisfy { $0.downloadedBytes != nil } ? 0 : 1)
                } catch {
                    FileHandle.standardError.write(Data("无法生成接口验证报告。\n".utf8))
                    await model.shutdown()
                    exit(1)
                }
            }
            return
        }
        #endif
        // 同一个签名应用读取同一个钥匙串条目，命令行只返回脱敏鉴权结果。
        if ProcessInfo.processInfo.arguments.contains("--verify-quark-session") {
            NSApp.setActivationPolicy(.prohibited)
            NSApp.windows.forEach { $0.orderOut(nil) }
            Task {
                await model.quark.start()
                do {
                    let report = try model.quark.verificationReport()
                    FileHandle.standardOutput.write(report + Data([10]))
                    if case .loggedIn = model.quark.state { exit(0) }
                    exit(1)
                } catch {
                    FileHandle.standardError.write(Data("无法生成夸克登录验证结果。\n".utf8))
                    exit(1)
                }
            }
            return
        }
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        if DemoData.isEnabled, let appearance = DemoData.appearance { NSApp.appearance = appearance }
        #endif
        Task { await model.start() }
    }

    /// 复制分享链接后切换到 Ferry，自动打开添加链接。
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await model.detectCopiedLink() }
    }

    /// 关闭主窗口不退出，下载继续。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 主窗口关闭后点击 Dock 图标，重新打开主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let openMainWindow = model.openMainWindow {
            openMainWindow()
            return false
        }
        return true
    }

    /// 等下载引擎保存进度后再退出，下次启动才能从断点继续。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
