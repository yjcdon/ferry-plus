# 4.1 工具栏与搜索实施记录

对应任务：T07。日期：2026-10-29。

- 传输工具栏分为分享链接、暂停／继续与详情、搜索三组；macOS 26 用公开的 ToolbarSpacer 分组，并通过 solidToolbarBackground 隐藏共享玻璃背景。
- 任务搜索复用 NSSearchField 和原焦点请求链路，按窗口宽度在 140—240 点间调整；⌘F、清除和即时筛选沿用已有实现。
- macOS 14 保留等价标准工具栏命令；实色窗口背景承担分组层级。

API 已核对本机 macOS 26.5 SDK 的 SwiftUI 接口，sharedBackgroundVisibility 受 macOS 26 可用性判断保护。官方说明：[sharedBackgroundVisibility](https://developer.apple.com/documentation/swiftui/toolbarcontent/sharedbackgroundvisibility(_:))。

语法解析、差异检查及完整 App 源码快照的 macOS 14 目标类型检查通过。工具栏收纳和焦点的实际操作由整合验收 C20—C22 承接。文件工作区工具栏由主代理在 NetdiskFilesView 同步接入。
