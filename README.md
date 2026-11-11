# Ferry Drive

Ferry Drive 是开源的百度网盘和夸克网盘桌面客户端，可在同一个原生窗口中管理文件、上传下载和处理分享链接。使用 Go 和 MyGo 构建，支持 Apple Silicon Mac 和 Windows 10／11 x64。

[下载 5.0.0](https://github.com/yjcdon/ferry-drive/releases/tag/v5.0.0) · [English](README.en.md) · [更新记录](CHANGELOG.md)

## 功能

- 同时登录百度网盘和夸克网盘，切换账号目录，搜索、排序和多选文件。
- 上传文件和文件夹，支持 Finder 拖放。下载网盘文件或分享链接，保留目录结构。
- 在文件列表中新建文件夹、重命名和批量移入网盘回收站。
- 在传输列表中暂停、继续、重试任务，并按网盘、方向或状态筛选。

## 安装

| 平台 | 下载和安装 |
| --- | --- |
| macOS 14+，Apple Silicon | 下载 `ferry-drive-5.0.0-darwin-arm64.zip`，解压后将 **Ferry Drive.app** 拖入「应用程序」。本版使用 Apple Development 签名，尚未经过 Apple 公证。 |
| Windows 10／11 x64 | 运行 `ferry-drive-setup-5.0.0-amd64.exe`，或解压 `ferry-drive-5.0.0-windows-amd64-portable.zip` 后运行 **Ferry Drive.exe**。网页登录需要 Microsoft Edge WebView2 Runtime。 |

打开「账号与设置」，通过网盘网页登录。选择网盘后即可上传、下载或在传输列表中查看任务。

macOS 也可以用 Homebrew 安装。

```sh
brew tap yjcdon/ferry-drive https://github.com/yjcdon/ferry-drive
brew install --cask yjcdon/ferry-drive/ferry-drive
```

如果已经通过旧 Tap 安装 `ferry-plus`，运行 `brew update` 和 `brew migrate --cask yjcdon/ferry-plus/ferry-plus`，再运行 `brew upgrade --cask --greedy yjcdon/ferry-plus/ferry-drive`。

新版可从 GitHub Releases 下载并手动安装。Ferry Plus 4.2 用户可单独安装 Ferry Drive，5.0 使用独立的账号和任务数据。

## 开发与许可

[5.0 技术方案与发布说明](docs/v5.0/architecture.md) · [设计文档](docs/README.md) · [问题反馈](https://github.com/yjcdon/ferry-drive/issues)

项目基于 [Ferry / BaiduPCS-Swift](https://github.com/yiquncode/BaiduPCS-Swift)，百度接口用法参考 [BaiduPCS-Go](https://github.com/qjfoidnh/BaiduPCS-Go)。采用 [Apache License 2.0](LICENSE)。

旧版 macOS 应用见 [Ferry Plus 4.2.0](https://github.com/yjcdon/ferry-drive/releases/tag/v4.2.0)。
