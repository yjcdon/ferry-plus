# Ferry Plus

[![release](https://img.shields.io/github/v/release/yjcdon/ferry-plus?label=release&color=black)](https://github.com/yjcdon/ferry-plus/releases/latest)
![macOS](https://img.shields.io/badge/macOS-14%2B-black)
[![license](https://img.shields.io/github/license/yjcdon/ferry-plus?color=blue)](LICENSE)

Ferry Plus 是一款简洁的 macOS 原生百度网盘、夸克网盘下载器，基于 [Ferry](https://github.com/yiquncode/BaiduPCS-Swift)，使用 Swift 和 SwiftUI 开发，专为 Apple Silicon Mac 构建。

[下载 Ferry Plus 2.0](https://github.com/yjcdon/ferry-plus/releases/tag/v2.0) · [更新记录](CHANGELOG.md)

支持分享链接和账号内文件下载，两家账号可同时登录，共用下载队列。下载速度受网盘服务和账号权限限制。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/screenshot-dark.png">
  <img src=".github/screenshot-light.png" alt="Ferry 主窗口：侧边栏按状态列出任务，右边是转存中、下载中、等待、失败和已完成的任务" width="1100">
</picture>

## 当前功能

- **双网盘下载**：支持百度、夸克分享链接和账号内文件下载，保留所选目录结构；文件窗口通过 Tab 切换网盘，默认打开百度。
- **双网盘登录**：通过百度、夸克的官方网页完成登录，分别保存账号状态；账号菜单同步显示账号名，并可单独退出。
- **统一任务列表**：按网盘、状态和文件名筛选；批量操作遵守当前可见范围。
- **断点恢复**：支持暂停、继续、退出恢复和地址刷新；分享转存保存各批回执，完成后按设置清理本任务目录。
- **独立设置**：两家分别设置转存目录、完成清理和单文件连接数，共用全局同时下载文件数。
- **本机保存凭据**：登录凭据存入 macOS Keychain，应用直接访问网盘服务。

2.0 已发布。两家真实下载、夸克跨层转存及清理、暂停与退出恢复、网络恢复、错误提取码及大目录浏览已通过验证；真实 CDN 地址自然过期和物理睡眠恢复仍待实测。详细范围和进度见 [功能清单](docs/features.md)、[架构设计](docs/architecture.md) 和 [任务清单](docs/tasks.md)。上图沿用 Ferry 的界面截图。

## 3.0 开发进度

当前源码构建版本为 3.0，尚未发布。已接入百度、夸克本地文件／文件夹上传、选定网盘后的拖放入口、发送后完整 SHA-256 回读，以及上传与下载统一任务列表。网盘文件与文件夹可移入回收站；下载支持指定摘要、本地复验及独立保留校验记录。

百度已接入安全覆盖：新内容校验后发布，保留独立云端旧版本，遇到并发冲突停止覆盖；已有实际 App 上传、发布及新旧文件下载摘要比对。夸克当前仍支持保留两份和跳过。夸克覆盖、部分未知提交／过期会话恢复及界面收尾仍未完成；按用户要求，不再追加生命周期和最终资源专项验收，已有代码质量要求保留。详细范围见 [3.0 功能清单](docs/v3/features.md)、[架构设计](docs/v3/architecture.md) 和 [任务清单](docs/v3/tasks.md)。上方下载链接继续指向已发布的 2.0。

## 系统要求

- macOS 14 或更高版本
- Apple Silicon（arm64）Mac

## 安装

从 [2.0 Release](https://github.com/yjcdon/ferry-plus/releases/tag/v2.0) 下载 `Ferry-Plus-2.0-arm64.zip`，解压后把 `Ferry Plus.app` 拖到“应用程序”文件夹即可，无需 DMG。发布页同时提供 SHA-256 校验文件。

可与原版 Ferry 共存；两者的登录凭据、设置及任务数据独立。

Ferry Plus 没有经过 Apple 公证。第一次打开时，如果 macOS 阻止运行，打开“系统设置 → 隐私与安全性”，在“安全性”中点击“仍要打开”。首次访问保存的凭据或切换签名身份时，系统可能要求允许访问钥匙串。

## 本机构建

本机构建使用 Command Line Tools，不需要安装完整 Xcode。当前已验证的环境为 Swift 6.4、macOS 26.5 SDK；完整 Xcode 也可用于工程构建。

```sh
bash Scripts/build-app.sh
open ".build/Ferry Plus.app"
```

脚本输出可直接运行的 `.app`。SDK 可通过 `FERRY_MACOS_SDK` 指定，具体构建和登录验证记录见 [登录说明](docs/login.md)。

默认构建 Debug，交付使用 `FERRY_BUILD_CONFIGURATION=release bash Scripts/build-app.sh`，为包与应用启用优化；两种模式复用同一签名身份和 App 路径。

Release App 构建完成后，运行 `bash Scripts/package-app.sh` 生成 `.build/dist/` 下的 arm64 ZIP 和 SHA-256 文件。打包前核对应用标识、架构和签名；该命令打包已有 App，不改变构建模式。默认解压为可直接运行的 `Ferry Plus.app`；可选 App 路径会保留该 App 的名称。

本机构建自动复用唯一有效的代码签名证书，保持重建后的钥匙串授权。存在多个证书时，通过 `FERRY_CODESIGN_IDENTITY` 指定证书名称或 SHA-1；无证书时使用临时签名并提示重建授权限制，也可显式指定 `-` 使用临时签名。无需把本机证书信息写入仓库。

本机构建与 Release 工作流均生成非沙盒 App，使用相同的应用标识及用户数据目录，保持登录、设置和任务存储位置一致。

现有 Swift 包测试同样可使用 Command Line Tools 执行：

```sh
bash Scripts/test-packages.sh
```

## 项目结构

```
BaiduPCS-Swift/          Ferry Plus.app：SwiftUI 界面、Keychain、下载目录权限、应用生命周期
Packages/FerryKit/
├── FerryCore            任务流程：任务模型、任务列表、JobCoordinator、设置
├── BaiduKit             百度协议：凭据、分享、转存、网盘操作、下载链接
├── QuarkKit             夸克登录、文件、分享、转存与下载接口
└── DownloadKit          通用分片下载：分片、并发、断点续传、进度持久化
Scripts/                本机 .app 构建、ZIP 打包与包测试
docs/                   功能、架构、任务和验证记录
```

## 致谢

本项目基于 [yiquncode/BaiduPCS-Swift（Ferry）](https://github.com/yiquncode/BaiduPCS-Swift)。百度网盘接口的用法参考了 [BaiduPCS-Go](https://github.com/qjfoidnh/BaiduPCS-Go)。

## 许可证

[Apache License 2.0](LICENSE)
