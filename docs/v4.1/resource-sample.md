# 4.1 资源采样

日期：2026-10-29。当前设备 Apple Silicon、系统报告 macOS 27.2。

内存目标：常规空闲物理占用约 100 MB。使用系统 `footprint`／`vmmap` 的 physical footprint 观察该目标，RSS 作为常驻页的补充指标。操作峰值与结束后的回落单独记录。

## 相同场景

串行运行 `/Applications/Ferry Plus.app` 4.0 发布版和 `.build/Ferry Plus.app` 4.1 Release 构建（采样源码 `a02e90a`）。使用相同账号和任务数据，半屏、隐藏侧栏，在百度样本目录进入一次子目录再返回三行列表。预热后间隔两秒取三次 `ps` CPU 与 RSS。

| 指标 | 4.0 | 4.1 |
| --- | --- | --- |
| App 磁盘占用 | 11924 KiB | 11964 KiB |
| ZIP 字节数 | 3845022 | 3854195 |
| 空闲 CPU 三次取样 | 0.3%、0%、0% | 0%、0%、0% |
| RSS 三次取样 | 142320、142320、142320 KiB | 136560、136512、136512 KiB |
| RSS 中位数 | 138.98 MiB | 133.31 MiB |

当前样本 App 增加 40 KiB，ZIP 增加 9173 字节；空闲 CPU 中位数均为 0%。RSS 表示进程驻留内存，本次结果用于相同短流程比较，长列表与连续操作的趋势继续单列验收。

原始记录：`.build/v41-evidence/resources-4.0.json`、`resources-4.1.json`。两版本串行启动后均读取既有登录和三行目录。

## 对象扫描对照

最新 Release 进程在界面读取前执行 `leaks -quiet`，结果为 0 对象／0 字节。随后同一进程连续读取 10 次辅助功能树，扫描报告 363 对象／17424 字节；根对象均为 `NSAccessibilityCustomAction`，已显示的处理闭包来自 AppKit `NSToolbarItemViewer.accessibilityCustomActions`。期间保持同一目录，业务操作保持空闲。

这组对照将报告的增长定位到辅助功能树读取关联的系统工具栏动作对象。当前引用图中可见对象均属上述类型；系统对已签名进程的调试限制继续适用。源码复核同时检查观察取消、弱引用及原生代理销毁。连续业务操作的趋势继续独立记录。

原始扫描保存在 `/tmp/ferry-v41-leaks-before-ax.log`、`/tmp/ferry-v41-leaks-after-ax.log`。

## 构建产物

保留 `.build/Ferry Plus.app`、`.build/dist/Ferry-Plus-4.1-arm64.zip` 与摘要文件。4.0 旧 ZIP 及摘要已移动至本机废纸篓。正式安装路径仍为 4.0。

后续窗口分栏与搜索裁切修复整合至 `858645a`，重建后 App 占用 12060 KiB，ZIP 为 3867487 字节。相对 4.0 分别增加 136 KiB 与 22465 字节。上表 CPU／RSS 保留原采样构建标识，最终整合构建的连续操作趋势继续验收。

分享行简化及路径修复整合至 `5f61c35`，最新 Release App 为 12140 KiB，ZIP 为 3880647 字节；相对 4.0 增加 216 KiB（约 1.81%）与 35625 字节（约 0.93%）。当前只保留这份 App 和对应 ZIP／摘要。此处更新包体数据，CPU／RSS 仍以表中标明的采样源码为准。

## 最新 Release 连续操作

源码 `5f61c35`，运行进程 54521。完成两家分享列表浏览后，在百度四行样本目录与夸克一行样本目录之间连续切换 12 次，分两轮各 6 次，每次均读到原生列表。操作前、第一轮后、第二轮后 RSS 分别为 169936、169296、169376 KiB（约 165.95、165.33、165.41 MiB），空闲 CPU 三次均为 0%。该短流程的内存保持稳定。原始记录：`/tmp/ferry-v41-continuous-before.log`、`round1.log`、`round2.log`（后两者共用 `ferry-v41-continuous-` 前缀）。长列表和更多业务场景继续单列。

## 物理内存与操作回落

同一 Release 构建，进程 55751 已完成分享下载、文件管理与列表操作。系统 `vmmap` 报告物理占用 98.6 MiB、历史峰值 181.3 MiB；随后 `heap` 报告物理占用 95.9 MiB，实际 malloc 分配约 50.5 MiB。历史峰值尚未归因。

以 `footprint` 逐阶段测量：普通传输页 96 MB → 展开约百项夸克分享列表 124 MB → 关闭后 120 MB → 自然回落 102 MB → 随后空闲 101 MB。该场景的日常占用接近目标，分享浏览产生短时增量。原始日志统一前缀 `/tmp/ferry-v41-memory-`：`vmmap.log`、`heap.log`、`before-share.log`、`open-share.log`、`after-share.log`、`after-share-settled.log`、`final-idle.log`。

`5df850f` 整合两处重复计算清理后重建 Release。新进程 60880 完成目录展开、勾选及刷新后，物理占用 57 MB，CPU 0%；日志 `latest-release.log`（同前缀）。新进程与旧进程的操作历史不同，此数值用于记录当前场景，长期操作结果继续沿用上述明确场景分别核对。最新 App 12140 KiB，ZIP 3880685 字节，旧 ZIP／摘要已移到废纸篓。
