# Ferry Plus 4.2.0 应用内更新技术方案

目标是让 GitHub 和 Homebrew 用户在 Ferry Plus 内查看更新内容、下载新版并原位替换当前应用。4.1.4 用户先通过原安装渠道升级一次到 4.2.0，之后进入应用内更新流程。首版面向 Apple Silicon、macOS 14 及以上，分发完整 ZIP。

## 用户操作与职责

| 编号 | 行为 | 实现 |
| --- | --- | --- |
| F1 检查 | 应用菜单提供「检查更新」，设置提供「自动检查更新」，默认每日检查。手动检查反馈当前结果，后台无新版时保持安静。 | 应用级共享一个 Sparkle 2 标准更新控制器。设置直接读写其检查偏好。 |
| F2 下载 | 发现新版时显示版本和本次发布说明，可选择更新或稍后。下载与网盘任务独立。 | Sparkle 读取固定 HTTPS 更新清单，按其中的版本专属地址下载 ZIP，显示进度并验证签名。 |
| F3 安装 | 下载完成后由用户确认重启。传输中先保留更新包，任务结束后再允许安装。 | 用更新器安装前委托对接任务引擎。安装前再次检查上传、下载及收尾校验，进入退出阶段后停止接受新任务。经过 AppDelegate 现有异步退出流程、等待 AppModel.shutdown() 完成，再由 Sparkle 的辅助程序替换并启动新版。暂停或排队的任务应持久化。 |
| F4 发布 | 两种安装渠道使用同一个正式包和同一份更新说明。 | 发布脚本从 CHANGELOG.md 取本版本内容，生成 GitHub Release 说明和更新清单中的内嵌说明。Cask 标记 auto_updates true，继续维护版本与 SHA-256。 |

安装推迟时继续使用当前版本，由用户决定重启时机。网络失败可重试，签名错误中止安装，目录权限不足时由系统处理授权，取消则回到旧版。更新仅替换 App 包。验收以实际读取原账号、设置、任务和书签为准。

## 构建与发布约束

1. 固定 Sparkle 2 的具体版本和依赖校验值。现有命令行构建与 Xcode 工程都链接、嵌入框架，保留辅助程序权限和符号链接。继续使用 ditto 完整打包，记录接入前后的 ZIP、App 大小及空闲内存。
2. Config/Version.xcconfig 统一管理展示版本和递增的内部构建号。当前 Scripts/build-app.sh 写死内部版本 1，Release workflow 则使用运行编号。两个入口改读同一配置，正式发布校验构建号高于上次正式版。
3. 区分应用代码签名和更新包签名。正式包固定应用身份及 Bundle ID，拒绝当前 CI 的临时签名回退。首轮先验证现有签名在目标机器上的启动、更新及钥匙串连续性。公开分发如采用 Developer ID 和公证，证书迁移另做真实升级验证。
4. 安装包嵌入 Ed25519 公钥。发布私钥在发布机钥匙串保存并安全备份，自动发布时通过受保护的 CI Secret 注入。使用支持签名清单的 Sparkle 版本，签名 ZIP 和最终清单，启用解压前验证。
5. 固定清单地址为仓库 main 分支的 updates/appcast.xml（raw.githubusercontent.com）。清单链接同仓库 GitHub Release 的版本专属 ZIP，标明构建号、展示版本、最低系统。先发布并回读验证 ZIP，再更新清单与 Cask。测试版使用独立清单及密钥。正式发布失败保留上一份有效清单，重试复用已验证的同一 ZIP。
6. 发现问题时从清单撤下问题版本，已安装用户通过更高构建号的修正版更新。正式包由一个发布入口生成，避免手工发布与标签工作流重复上传不同签名的包。

依据：[Sparkle 集成](https://sparkle-project.org/documentation/)、[发布与版本比较](https://sparkle-project.org/documentation/publishing/)、[更新偏好与验证](https://sparkle-project.org/documentation/customization/)、[Homebrew Cask](https://docs.brew.sh/Cask-Cookbook)。
