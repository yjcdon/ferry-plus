# 4.1 工具栏与搜索实施记录

对应任务：T07。日期：2026-10-29。

- 传输工具栏分为分享链接、暂停／继续与详情、搜索三组；macOS 26 宽窗用公开的 ToolbarSpacer 分组，内容区小于 700 点时省去固定间隔，并通过 solidToolbarBackground 隐藏共享玻璃背景。
- 任务搜索复用 NSSearchField 和原焦点请求链路，按窗口宽度在 160—240 点间调整；⌘F、清除和即时筛选沿用已有实现。实际控件内距测量见[搜索尺寸记录](search-sizing-implementation.md)。
- 传输内容区低于 520 点时，添加分享链接、暂停／继续当前列表和显示／隐藏详情统一收入【操作】菜单，优先保留独立 160 点搜索。菜单与平铺布局共用原动作及能力计算，菜单显示完整文字标签；常规宽度保持原分组。最窄窗口菜单可达性和搜索可见性由整合构建实测。
- macOS 14 保留等价标准工具栏命令；实色窗口背景承担分组层级。
- 宽窗文件页与传输页在动作组前加入公开的 `ToolbarSpacer(.flexible, placement: .primaryAction)`，由弹性间距吸收左侧空间，使动作和独立搜索靠右排列；低于 700 点内容宽度时沿用紧凑收纳。该增强受 macOS 26 可用性保护，macOS 14 沿用原生布局。依据：[ToolbarSpacer](https://developer.apple.com/documentation/swiftui/toolbarspacer) 与 [flexible](https://developer.apple.com/documentation/swiftui/spacersizing/flexible)；SDK 26.5 声明已核对，实际宽窗排列由整合构建验收。
- 实色衬底内的文件操作和传输操作逐按钮显式声明辅助名称，详情按钮随显示状态、暂停／继续按钮随当前能力更新名称；菜单与独立原生搜索沿用已有业务名称。图标、帮助、分组和业务动作保持一致，独立名称由整合 App 的 AX 读取复验。
- 文件命令组、传输操作组及独立搜索复用 `toolbarControlSurface`：32 点高的系统实色胶囊衬底与 0.5 点语义描边，组内保持原按钮与命令。原生共享材质继续隐藏，分组、宽窄收纳和搜索焦点沿用原流程。
- 窗口沿用 AppKit 原生标题栏及空白背景拖动，实色配置明确开启窗口可移动属性；衬底描边只绘制外观，鼠标事件交给原按钮和搜索。使用最低支持系统已有的 [isMovableByWindowBackground](https://developer.apple.com/documentation/appkit/nswindow/ismovablebywindowbackground) 属性。
- 主窗口采用 `hiddenTitleBar` 与 `unified` 单行工具栏。导航标题是窗口名称的唯一来源；macOS 15 起通过公开的 `toolbar(removing: .title)` 移除系统重复标题，标题文字区域单独承接鼠标。拖动采用按下时的屏幕坐标与窗口原点，随 `mouseDragged` 更新窗口位置，`mouseUp` 清理起点；双击交给原生响应链，具体系统行为单列验收。按钮、搜索与列拖动继续使用各自事件。实际窗口位移仍待验证，工具目前返回 `noWindowsAvailable`；成功截图与 AX 查询分别记录。

API 已核对本机 macOS 26.5 SDK 的 SwiftUI 接口，sharedBackgroundVisibility 受 macOS 26 可用性判断保护。官方说明：[sharedBackgroundVisibility](https://developer.apple.com/documentation/swiftui/toolbarcontent/sharedbackgroundvisibility(_:))。

语法解析、差异检查及完整 App 源码快照的 macOS 14 目标类型检查通过。工具栏收纳和焦点的实际操作由整合验收 C20—C22 承接。文件工作区工具栏由主代理在 NetdiskFilesView 同步接入。
