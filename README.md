# Ferry Plus

**简洁的 macOS 百度网盘与夸克网盘客户端。**

用一个原生 Mac 应用浏览网盘、上传下载和管理文件。基于 [Ferry](https://github.com/yiquncode/BaiduPCS-Swift)，使用 Swift 与 SwiftUI 开发。

[下载最新版](https://github.com/yjcdon/ferry-plus/releases/latest) · [English](README.en.md) · [更新记录](CHANGELOG.md)

支持 **macOS 14+ · Apple Silicon（M 系列芯片）**，采用 Apache 2.0 开源许可证。

## 能做什么

- **双网盘管理**：同时登录百度和夸克，在侧边栏切换；浏览目录、搜索当前目录、排序和调整列宽。
- **上传与下载**：上传文件或文件夹，支持拖放；下载网盘文件和分享链接，保留目录结构。
- **文件操作**：在列表空白处右键新建文件夹；支持重命名、批量移入网盘回收站。
- **传输管理**：暂停、继续、失败重试，按网盘、上传／下载和状态筛选任务。
- **内容检查**：在后台核对传输内容，登录凭据保存在本机 macOS 钥匙串中。

上传时选择文件或文件夹后直接开始，也可拖入当前目录或目标文件夹。同名文件默认保留两份，进度在传输列表查看。

## 安装

### Homebrew

```sh
brew tap yjcdon/ferry-plus https://github.com/yjcdon/ferry-plus
brew install --cask yjcdon/ferry-plus/ferry-plus
```

升级：

```sh
brew update
brew upgrade --cask yjcdon/ferry-plus/ferry-plus
```

如果 Homebrew 提示信任安装源，执行 `brew trust --cask yjcdon/ferry-plus/ferry-plus` 后重新安装。

### 直接下载

前往 [Releases](https://github.com/yjcdon/ferry-plus/releases/latest)，下载 `Ferry-Plus-版本号-arm64.zip`，解压后将 **Ferry Plus.app** 拖入“应用程序”。发布页提供 SHA-256 校验文件。

应用当前未经过 Apple 公证。首次打开若被系统拦截，可在“系统设置 → 隐私与安全性”中选择“仍要打开”。

## 开始使用

1. 打开“账号与设置”，通过网盘官方网页登录百度或夸克。
2. 在侧边栏选择网盘，浏览文件；拖入本地文件即可上传，勾选云端文件后点击下载。
3. 在“传输”中查看进度，点击“查看全部”汇总两家网盘的任务。

分享链接可通过工具栏的链接按钮添加。

## 常见问题

**下载速度由什么决定？** 取决于网络、网盘服务和账号权限。并发设置用于调整连接数，会员权益由网盘服务提供。

**支持哪些 Mac？** macOS 14 及以上的 Apple Silicon Mac，即 M 系列芯片机型。

**登录信息保存在哪里？** 凭据保存在本机 macOS 钥匙串中，应用直接访问网盘服务。发布包只包含程序和资源；账号与任务数据保存在各自的 Mac 上。

**与原版 Ferry 有什么区别？** Ferry Plus 在 Ferry 基础上加入夸克网盘、双网盘上传和文件管理，统一浏览与传输界面。两款应用可共存，账号与设置分别保存。

## 开发与反馈

遇到问题或有建议，欢迎提交 [Issue](https://github.com/yjcdon/ferry-plus/issues)。请附上应用版本、macOS 版本和复现步骤，并遮盖账号及私人文件信息。

[本机构建](docs/build.md) · [设计文档](docs/README.md) · [验证与待完善事项](docs/v4.1/test-execution.md)

## 致谢与许可

基于 [Ferry / BaiduPCS-Swift](https://github.com/yiquncode/BaiduPCS-Swift)，百度接口用法参考 [BaiduPCS-Go](https://github.com/qjfoidnh/BaiduPCS-Go)。

[Apache License 2.0](LICENSE)
