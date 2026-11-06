# Ferry Plus 本机构建

本机构建使用 Command Line Tools，不需要安装完整 Xcode。当前已验证的环境为 Swift 6.4、macOS 26.5 SDK；完整 Xcode 也可用于工程构建。

```sh
bash Scripts/build-app.sh
open ".build/Ferry Plus.app"
```

脚本输出可直接运行的 `.app`。SDK 可通过 `FERRY_MACOS_SDK` 指定，具体构建和登录验证记录见 [登录说明](login.md)。

默认构建 Debug，交付使用 `FERRY_BUILD_CONFIGURATION=release bash Scripts/build-app.sh`，为包与应用启用优化；两种模式复用同一签名身份和 App 路径。

Release App 构建完成后，运行 `bash Scripts/package-app.sh` 生成 `.build/dist/` 下的 arm64 ZIP 和 SHA-256 文件。打包前核对应用标识、架构和签名；该命令打包已有 App，不改变构建模式。默认解压为可直接运行的 `Ferry Plus.app`；可选 App 路径会保留该 App 的名称。

本机构建自动复用唯一有效的代码签名证书，保持重建后的钥匙串授权。存在多个证书时，通过 `FERRY_CODESIGN_IDENTITY` 指定证书名称或 SHA-1；Debug 无证书时使用临时签名。Release 构建与打包要求固定证书身份。无需把本机证书信息写入仓库。

本机构建与 Release 工作流均生成非沙盒 App，使用相同的应用标识及用户数据目录，保持登录、设置和任务存储位置一致。

现有 Swift 包测试同样可使用 Command Line Tools 执行：

```sh
bash Scripts/test-packages.sh
```

## 项目结构

```
BaiduPCS-Swift/          Ferry Plus.app：SwiftUI 界面、Keychain、下载目录权限、应用生命周期
Packages/FerryKit/
├── FerryCore            任务流程：上传／下载队列、流式校验、任务存储与设置
├── BaiduKit             百度协议：凭据、分享、转存、网盘操作、下载链接
├── QuarkKit             夸克登录、文件、分享、转存、上传与下载接口
└── DownloadKit          通用分片下载：分片、并发、断点续传、进度持久化
Scripts/                本机 .app 构建、ZIP 打包与包测试
docs/                   功能、架构、任务和验证记录
```


## 4.2.0 更新构建与发布

首次构建自动下载并校验固定版本 Sparkle。Config/Version.xcconfig 中的展示版本和内部构建号供两个构建入口共用，每次正式发布递增内部构建号。

Config/Updates.xcconfig 存放正式清单地址和公钥。发布钥匙串账号为 io.github.yjcdon.FerryPlus.updates。私钥通过钥匙串管理，发布者另行安全备份。CI 使用 release 环境的 FERRY_CERTIFICATE_P12、FERRY_CERTIFICATE_PASSWORD、FERRY_CODESIGN_IDENTITY、FERRY_UPDATE_PRIVATE_KEY，首次启用时配置。

构建并打包后，使用 Scripts/prepare-update.py 生成已签名清单、发布说明和候选 Cask。Scripts/publish-update.sh 在回读验证 ZIP 后提交正式清单与 Cask，最后设置 GitHub 最新版。发布前先完成 docs/v4.2.0/test-cases.md 的实际升级验收。

隔离测试使用 FERRY_UPDATE_TESTING=1，同时设置 FERRY_UPDATE_FEED_URL、FERRY_UPDATE_PUBLIC_KEY 和 FERRY_BUILD_NUMBER。测试签名账号为 io.github.yjcdon.FerryPlus.update-tests。测试包仅用于验收，正式发布工具会校验正式源与公钥。
