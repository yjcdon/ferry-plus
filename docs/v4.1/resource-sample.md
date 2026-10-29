# 4.1 资源采样

日期：2026-10-29。当前设备 Apple Silicon、系统报告 macOS 27.2。

## 相同场景

串行运行 `/Applications/Ferry Plus.app` 4.0 发布版和 `.build/Ferry Plus.app` 4.1 Release 构建。使用相同账号和任务数据，半屏、隐藏侧栏，在百度样本目录进入一次子目录再返回三行列表。预热后间隔两秒取三次 `ps` CPU 与 RSS。

| 指标 | 4.0 | 4.1 |
| --- | --- | --- |
| App 磁盘占用 | 11924 KiB | 11964 KiB |
| ZIP 字节数 | 3845022 | 3854195 |
| 空闲 CPU 三次取样 | 0.3%、0%、0% | 0%、0%、0% |
| RSS 三次取样 | 142320、142320、142320 KiB | 136560、136512、136512 KiB |
| RSS 中位数 | 138.98 MiB | 133.31 MiB |

当前样本 App 增加 40 KiB，ZIP 增加 9173 字节；空闲 CPU 中位数均为 0%。RSS 表示进程驻留内存，本次结果用于相同短流程比较，长列表与连续操作的趋势继续单列验收。

原始记录：`.build/v41-evidence/resources-4.0.json`、`resources-4.1.json`。两版本串行启动后均读取既有登录和三行目录。

## 构建产物

保留 `.build/Ferry Plus.app`、`.build/dist/Ferry-Plus-4.1-arm64.zip` 与摘要文件。4.0 旧 ZIP 及摘要已移动至本机废纸篓。正式安装路径仍为 4.0。
