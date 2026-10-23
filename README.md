# Ferry Plus

[![release](https://img.shields.io/github/v/release/yjcdon/ferry-plus?label=release&color=black)](https://github.com/yjcdon/ferry-plus/releases/latest)
![macOS](https://img.shields.io/badge/macOS-14%2B-black)
[![license](https://img.shields.io/github/license/yjcdon/ferry-plus?color=blue)](LICENSE)

Ferry Plus 基于 [Ferry](https://github.com/yiquncode/BaiduPCS-Swift)，使用 Swift 和 SwiftUI 构建 macOS 原生下载工具，面向百度网盘和夸克网盘。下载速度受网盘服务和账号权限限制。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/screenshot-dark.png">
  <img src=".github/screenshot-light.png" alt="Ferry 主窗口：侧边栏按状态列出任务，右边是转存中、下载中、等待、失败和已完成的任务" width="1100">
</picture>

## 当前功能

- **百度网盘下载**：保留上游的分享链接下载和网盘文件下载流程。
- **双网盘登录**：通过百度、夸克的官方网页完成登录，分别保存账号状态。
- **无服务器**：Cookie 凭据存在 macOS Keychain 中，不经过第三方。

夸克下载、网盘切换和按网盘划分的批量操作正在开发，详细范围和进度见 [功能清单](docs/features.md)、[架构设计](docs/architecture.md) 和 [任务清单](docs/tasks.md)。上图沿用 Ferry 的界面截图。

## 系统要求

- macOS 14 或更高版本
- Apple Silicon（arm64）Mac

## 安装

从 [Releases](https://github.com/yjcdon/ferry-plus/releases) 下载已发布的 `Ferry-Plus-<版本>-arm64.zip`，解压后把 `Ferry Plus.app` 拖到“应用程序”文件夹。每个版本同时提供 SHA-256 校验文件。

Ferry Plus 没有经过 Apple 公证。第一次打开时，如果 macOS 阻止运行，打开“系统设置 → 隐私与安全性”，在“安全性”中点击“仍要打开”。重新构建或更新后，系统可能要求再次允许访问钥匙串中的凭据。

## 本机构建

本机构建使用 Command Line Tools，不需要安装完整 Xcode。当前已验证的环境为 Swift 6.4、macOS 26.5 SDK；完整 Xcode 也可用于工程构建。

```sh
bash Scripts/build-app.sh
open ".build/Ferry Plus.app"
```

脚本输出可直接运行的 `.app`。SDK 可通过 `FERRY_MACOS_SDK` 指定，具体构建和登录验证记录见 [登录说明](docs/login.md)。

## 项目结构

```
BaiduPCS-Swift/          Ferry Plus.app：SwiftUI 界面、Keychain、下载目录权限、应用生命周期
Packages/FerryKit/
├── FerryCore            任务流程：任务模型、任务列表、JobCoordinator、设置
├── BaiduKit             百度协议：凭据、分享、转存、网盘操作、下载链接
├── QuarkKit             夸克协议与账号验证
└── DownloadKit          通用分片下载：分片、并发、断点续传、进度持久化
Scripts/                本机 .app 构建
docs/                   功能、架构、任务和验证记录
```

## 致谢

本项目基于 [yiquncode/BaiduPCS-Swift（Ferry）](https://github.com/yiquncode/BaiduPCS-Swift)。百度网盘接口的用法参考了 [BaiduPCS-Go](https://github.com/qjfoidnh/BaiduPCS-Go)。

## 许可证

[Apache License 2.0](LICENSE)
