# Ferry Drive 5.0 行为基线

T01 固定 Ferry Plus 4.2.0 源码 `449de5a5faf78f2fa8753d99877e84b12235f0fa`。下文尺寸以 macOS 点为单位。对应 [任务清单](tasks.md) 与 [测试用例](test-cases.md)。

## 页面与可达操作

| 场景 | 基准行为 | 源码 |
| --- | --- | --- |
| 主窗口 | 初始 960×640，最小 640×400。侧栏默认宽 200，范围 180～300，按顺序显示两家网盘、传输分类、底部「账号与设置」。默认进入百度文件页，重启恢复最近页面和网盘。侧栏按钮、搜索及主要操作在窄窗可达。 | [应用入口](../../BaiduPCS-Swift/BaiduPCS_SwiftApp.swift)、[主窗口](../../BaiduPCS-Swift/MainView.swift)、[侧栏](../../BaiduPCS-Swift/SidebarView.swift)、[页面状态](../../BaiduPCS-Swift/WorkspaceState.swift) |
| 文件页 | 面包屑位于文件表上方，宽度不足时中间层级收进「上级目录」菜单。未登录页保留目录导航，中部显示「登录百度网盘」或「登录夸克网盘」与「登录」按钮。可用目录的工具栏平铺上传、下载、移到回收站和刷新。内容宽小于 700 时收起目录动作，小于 520 时一并收起上传和下载。独立「搜索当前目录」宽 160～220。底部显示选择统计或操作进度。 | [文件页](../../BaiduPCS-Swift/NetdiskFilesView.swift) |
| 文件树表 | 行高 30、层级缩进 18，使用横分隔线。名称／修改日期／大小初始列宽 320／200／90，最小 180／100／60，支持拖列宽和横向滚动。默认按名称升序、目录优先。展开时加载，搜索筛当前目录直接子项。原生多选、键盘与勾选作用于同一操作集合，选中父目录后去重子项。无结果显示「试试其他关键词」，目录空显示「此目录为空」。 | [目录状态](../../BaiduPCS-Swift/DirectoryBrowserState.swift)、[树表](../../BaiduPCS-Swift/NetdiskOutlineView.swift)、[选择树](../../BaiduPCS-Swift/FileTree.swift) |
| 文件操作 | 空白处右键新建文件夹，行内命名并就地显示字段错误。行菜单提供下载、上传到此文件夹（目录）、重命名和移到回收站。回收站确认列出实际目标，宽按名称计算，通常下限 320，上限 720 且受屏幕可见宽度限制。首次读取失败显示「网盘读取失败」，可重试或重新登录。已有列表刷新失败保留内容并显示「更新失败：…」。 | [文件页](../../BaiduPCS-Swift/NetdiskFilesView.swift)、[树表](../../BaiduPCS-Swift/NetdiskOutlineView.swift) |
| 上传与下载 | 当前目录上传打开系统混合文件选择；目录行和空内容支持拖放。没有明确目标时，工作区显示待上传项数，选择目录后用「上传到当前目录」提交。账号内下载用确认面板，最小宽 600、理想 660，列出选择和保存目录。 | [上传入口](../../BaiduPCS-Swift/DirectUploadPresenter.swift)、[下载确认](../../BaiduPCS-Swift/DownloadConfirmationView.swift) |
| 传输 | 侧栏分类依次为全部、进行中、已完成、失败。工作区按网盘范围、方向和搜索收敛，默认方向全部。切换「查看全部」保留当前分类、方向和搜索。侧栏计数基于同一网盘、方向与搜索范围，列表和底部统计再应用当前分类。选中任务后按阶段开放操作，任务菜单也可暂停或继续当前列表。 | [主窗口](../../BaiduPCS-Swift/MainView.swift)、[下载行](../../BaiduPCS-Swift/JobListView.swift)、[上传行](../../BaiduPCS-Swift/UploadListView.swift) |
| 详情 | 右侧详情默认关闭，默认宽 320，最小 280；上限为工作区一半与内容宽减 328 的较小值。内容宽低于 640 时暂时隐藏，主动打开可收起侧栏。下载详情有文件状态、定位与移除，上传详情按阶段提供优先上传、取消、重选来源、失败项重试或远端核对。 | [主窗口](../../BaiduPCS-Swift/MainView.swift)、[详情](../../BaiduPCS-Swift/JobInspector.swift)、[上传行](../../BaiduPCS-Swift/UploadListView.swift) |
| 分享与登录 | 「添加链接」面板最小 600×460，理想 640×540，支持粘贴、提取码和文件树。两家官方登录用独立窗口。百度网页登录最小 720×600、理想 800×700，Cookie 补充页宽 500；夸克最小 800×600、理想 1000×720。会话校验通过才保存，关闭窗口清理会话。 | [分享](../../BaiduPCS-Swift/AddLinkView.swift)、[百度登录](../../BaiduPCS-Swift/LoginView.swift)、[网页登录](../../BaiduPCS-Swift/WebLoginView.swift)、[夸克登录](../../BaiduPCS-Swift/QuarkLoginView.swift) |
| 生命周期 | 主窗口关闭后传输继续，点击 Dock 重新打开主窗口；显式退出等待保存进度。回到前台时按设置检测新复制的分享链接。后台通知使用系统横幅和通知列表。 | [应用委托](../../BaiduPCS-Swift/AppDelegate.swift)、[应用状态](../../BaiduPCS-Swift/AppModel.swift)、[传输生命周期](../../BaiduPCS-Swift/TransferLifecycle.swift) |

界面以系统浅深色和实色表面为基准。对照时记录默认宽窗、640 点窄窗、表头与多选、任务详情、确认面板，以及空态、加载、选中、错误和禁用的状态差异。

## 快捷键

| 输入 | 基准行为 |
| --- | --- |
| ⌘N／⌘U | 添加链接／上传文件，按需唤起主窗口 |
| ⌘F／⌥⌘I | 搜索当前目录或任务／显示或隐藏详情 |
| ⌘A | 优先全选输入框文本，列表焦点下全选当前可见项 |
| ⌘X／⌘C／⌘V／⌥⇧⌘V | 原生剪切、拷贝、粘贴、粘贴并匹配样式 |
| 文件表空格／Return／⌘↓／⌘↑ | 切换焦点行选择／打开焦点目录／打开焦点目录／上一级 |
| 面板 Return／Escape | 执行当前默认动作／取消；行内输入沿用原生文本响应 |
| ⌘,／⌘W／⌘Q | 系统设置、关闭窗口和退出 |

来源为[菜单命令](../../BaiduPCS-Swift/BaiduPCS_SwiftApp.swift)与[文件表键盘事件](../../BaiduPCS-Swift/NetdiskOutlineView.swift)。Windows 组合键和 F2 依据 5.0 测试用例验收。

## 四类设置

设置窗口为 480×450，保存选中的标签页。4.2.0 第五个「更新」标签和应用菜单更新动作按 5.0 全新安装范围排除。

| 标签 | 默认值与范围 | 提交与反馈 |
| --- | --- | --- |
| 传输 | 下载目录为系统「下载」；同时下载 1 文件，基本范围 1～10；同时上传 1 任务，范围 1～4；每个上传文件 1 并发分片，范围 1～4；上传和下载限速均 0 KiB/s，0 表示不限速；剪贴板检测默认开启。 | 自选目录保存授权，访问失败有提示并回到系统下载目录。限速以 KiB/s 编辑，以字节/秒执行；上传校验回读计入下载额度。限速和并发设置提交后更新调度配置。 |
| 网盘 | 百度转存目录 `/Ferry`，夸克 `/Ferry Plus`；两家均默认清理转存文件，单文件连接均 1，基本范围 1～16。每家单文件连接数乘以同时下载文件数不超过 20，控件范围随另一项调整。 | 路径提交时去首尾空白并整理为绝对路径，空值恢复默认。Return 或离开标签时提交目录。 |
| 网络 | 默认「使用系统设置」；可选 SOCKS5，主机与端口无默认输入，`127.0.0.1` 与 `1080` 是占位文字。端口范围 1～65535，用户名和密码成对填写或留空。 | Return、离开所有输入框或离开标签时提交草稿；无效 SOCKS5 回到系统代理并显示字段反馈，空草稿暂不提示。密码独立保存在凭据存储。 |
| 账号 | 两家初始均待登录。 | 已登录显示账号及退出；失效显示重新登录，夸克暂时校验问题可重试。退出有确认。账号菜单、设置和主窗口共用会话。 |

来源为[设置界面](../../BaiduPCS-Swift/SettingsView.swift)、[默认值与并发范围](../../Packages/FerryKit/Sources/FerryCore/FerrySettings.swift)、[代理契约](../../Packages/FerryKit/Sources/FerryCore/ProxySettings.swift)与[配置生效路径](../../BaiduPCS-Swift/AppModel.swift)。

## 证据与历史差异

- [4.1 实机记录](../v4.1/test-execution.md)包含 640 点窗口、列宽、横向滚动、实色表面和旧任务详情的实际结果。[4.2.0 实机记录](../v4.2.0/test-execution.md)记录正式版本构建与更新设置，百度账号目录在该轮得到观察，夸克会话恢复待验证。这些记录的构建和用例编号各自独立。
- 早期文档的上传确认页、独立行焦点选择、早期工具栏动作数量以固定源码为准。可用目录的当前上传使用系统文件面板；表格选中、勾选与操作集合联动；新建文件夹入口在空白右键。
- 5.0 保留现有业务默认值，包括夸克远端转存目录名。4.2.0 更新功能与 4.x 数据导入不纳入 5.0。
- [现有测试脚本](../../Scripts/test-packages.sh)运行 `BaiduKitTests`、`DownloadKitTests`、`FerryCoreTests`，覆盖协议与账号、下载引擎与分段、任务协调与设置等。Debug 的 `-FerryDemo YES` 支持传输样本、未登录或空列表、浅深色、添加链接和设置标签。真实账号行为和云端写入另用隔离样本验证。

## 同机截图

在 Apple Silicon Mac 上用 `bash Scripts/build-app.sh` 重建固定源码并启动 Debug 演示模式。截图使用隔离样本，窗口默认 960×640，窄窗检查设为 640×400。

| 场景 | 证据 |
| --- | --- |
| 两家网盘未登录 | [百度浅色](evidence/4.2.0/baidu-signed-out.png)、[夸克深色](evidence/4.2.0/quark-signed-out.png) |
| 传输页 | [进行中与详情](evidence/4.2.0/transfers-detail.png)、[失败深色](evidence/4.2.0/transfers-dark.png)、[窄窗](evidence/4.2.0/transfers-narrow.png) |
| 分享链接 | [默认焦点与禁用状态](evidence/4.2.0/share-link.png) |
| 四类设置 | [传输](evidence/4.2.0/settings-0.png)、[网盘](evidence/4.2.0/settings-1.png)、[网络](evidence/4.2.0/settings-2.png)、[账号](evidence/4.2.0/settings-3.png) |

真实目录及其加载状态、下载与回收站确认、登录验证和行内错误以源码及历史记录为基准，实机对照随对应功能采集。后续结果见[实施与测试记录](test-execution.md)。
