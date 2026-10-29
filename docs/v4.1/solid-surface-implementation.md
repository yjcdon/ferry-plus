# 4.1 实色窗口与面板基础

日期：2026-10-29。对应 T13、F-11，遵循 hig-product-experience 的 macOS 14 兼容和实色规则。

## 实现

- `solidWindowSurface()` 为主窗口、两家登录窗口和设置提供不透明 `windowBackgroundColor`，并用 SwiftUI 公开工具栏背景 API 设置实色。
- `SolidWindowConfigurator` 在视图连接窗口时设置 `NSWindow.isOpaque`、`backgroundColor`、`titlebarAppearsTransparent` 和标题栏分隔线。属性变化时才更新，保持原生窗口操作。
- `solidToolbarBackground()` 在 macOS 26 及以上调用公开的 `ToolbarContent.sharedBackgroundVisibility(.hidden)`，将自动共享背景交由实色工具栏承载；macOS 14 使用原有标准工具栏项目。
- `solidSheetSurface()` 使用内容背景和 `presentationBackground`，接入上传、下载和分享确认面板；其他业务面板沿用同一方法接入。
- 共享 `edgeBar` 的全部调用方（传输列表、任务详情、侧栏）改用 `safeAreaInset`、实色填充和轻分隔线。登录反馈栏与提示详情也使用实色。

窗口配置仅在 NSView 更新及连接窗口时执行，使用公开属性。实现采用直接视图引用，无观察器、计时器或持续调度任务。

## 验证

`SolidWindowSurface.swift` 使用本机 26.5 SDK、`arm64-apple-macos14.0` 目标独立类型检查通过。SDK 声明确认共享背景 API 最低 macOS 26，调用有版本判断。确认面板背景 API 支持本项目最低运行版本。

主代理整合后重新构建真实 App，逐项记录工具栏、侧栏、详情、面板与设置外观。系统菜单、系统文件选择器和服务方登录网页由其所属系统或服务绘制；其实际外观在运行验收中单独记录。

## 外观验收参数

Debug 构建可单独使用 `-FerryDemoAppearance dark` 或 `light` 指定 App 外观，配合 `-FerryDemo NO` 复用真实账号检查文件页、上传及下载面板。账号与任务模式仍由 `FerryDemo` 控制，系统外观偏好保持用户设置。该分支仅参与 Debug 构建。
