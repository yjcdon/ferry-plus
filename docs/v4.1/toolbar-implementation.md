# 4.1 工具栏与搜索实施记录

对应任务：T07。日期：2026-10-29。

- 传输工具栏分为分享链接、暂停／继续与详情、搜索三组；macOS 26 宽窗用公开的 ToolbarSpacer 分组，内容区小于 700 点时省去固定间隔，并通过 solidToolbarBackground 隐藏共享玻璃背景。
- 任务搜索复用 NSSearchField 和原焦点请求链路，按窗口宽度在 160—240 点间调整；⌘F、清除和即时筛选沿用已有实现。实际控件内距测量见[搜索尺寸记录](search-sizing-implementation.md)。
- 传输内容区低于 520 点时，添加分享链接、暂停／继续当前列表和显示／隐藏详情统一收入【操作】菜单，优先保留独立 160 点搜索。菜单与平铺布局共用原动作及能力计算，菜单显示完整文字标签；常规宽度保持原分组。最窄窗口菜单可达性和搜索可见性由整合构建实测。
- macOS 14 保留等价标准工具栏命令；实色窗口背景承担分组层级。
- 文件命令组、传输操作组及独立搜索复用 `toolbarControlSurface`：32 点高的系统实色胶囊衬底与 0.5 点语义描边，组内保持原按钮与命令。原生共享材质继续隐藏，分组、宽窄收纳和搜索焦点沿用原流程。
- 窗口沿用 AppKit 原生标题栏及空白背景拖动，实色配置明确开启窗口可移动属性；衬底描边只绘制外观，鼠标事件交给原按钮和搜索。使用最低支持系统已有的 [isMovableByWindowBackground](https://developer.apple.com/documentation/appkit/nswindow/ismovablebywindowbackground) 属性。

API 已核对本机 macOS 26.5 SDK 的 SwiftUI 接口，sharedBackgroundVisibility 受 macOS 26 可用性判断保护。官方说明：[sharedBackgroundVisibility](https://developer.apple.com/documentation/swiftui/toolbarcontent/sharedbackgroundvisibility(_:))。

语法解析、差异检查及完整 App 源码快照的 macOS 14 目标类型检查通过。工具栏收纳和焦点的实际操作由整合验收 C20—C22 承接。文件工作区工具栏由主代理在 NetdiskFilesView 同步接入。
