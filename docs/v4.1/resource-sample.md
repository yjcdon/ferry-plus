# 4.1 资源采样

日期：2026-10-29。当前设备 Apple Silicon、系统报告 macOS 27.2。

内存目标：常规空闲物理占用约 100 MB。使用系统 `footprint`／`vmmap` 的 physical footprint 观察该目标，RSS 作为常驻页的补充指标。操作峰值与结束后的回落单独记录。

用户再次确认将约 100 MB 作为日常使用目标。验收覆盖文件浏览、传输列表及上传结束后的空闲场景，并观察连续操作的回落情况。

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

## 上传场景补充

源码 `f24cb22`，Release 进程 64573。在最窄窗口通过文件菜单上传百度样本 `parts.bin`（12,582,929 字节）。上传开始前至上传早期共 40 次物理占用采样，范围 72–83 MB，原始记录为 `.build/v41-evidence/upload-memory-latest.json`。这段采样覆盖上传的前一阶段。

随后真实界面显示该任务【已完成 · 12.6 MB】，百度范围 16 个任务全部完成。完成后的物理占用为 75 MB，进程历史峰值 101 MB，空闲 CPU 0%，复查 RSS 123440 KiB（约 120.5 MiB）。物理占用及 CPU 的复查记录为 `/tmp/ferry-v41-memory-upload-completed.log`。本场景达到日常约 100 MB 的物理占用目标；长列表等场景继续按各自操作记录判断。

## 复用与设置精简后的整合构建

源码 `ea38804`，Release 进程 93155。完成设置分类切换、三类并发计数增减恢复及工具栏浏览后，物理占用 85 MB、该进程历史峰值 108 MB。原始记录 `.build/v41-evidence/final-settings-footprint.log`。

从 `b901859` 到该源码，生产目录共增加 107 行、删除 220 行，净减少 113 行，包含闲置接口清理、公共控件复用、重复遍历减少，以及用户指定的设置精简和工具栏衬底。App 为 12460 KiB，最新 ZIP 为 3913358 字节；包体采用实际构建值。六个包内文件与 App 摘要一致，记录 `.build/v41-evidence/package-latest.json`，上一份 ZIP 和摘要已移入废纸篓。

## 标题拖动与工具栏收尾构建

源码 `3b39c72`，Release 进程 15922。实际文件页及正反向标题区域拖动后，物理占用 51 MB、峰值 54 MB、空闲 CPU 0%，RSS 140304 KiB。本次为该有限交互流程的资源记录，原始文件 `.build/v41-evidence/final-title-footprint.log`。

最终 ZIP 为 3937630 字节，六个文件与当前 App 内容一致；构建目录保留最新 App、ZIP 及摘要，旧 ZIP 与摘要已移到废纸篓。
