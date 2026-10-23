# 登录实现与本机构建

## 当前已实现范围

- 独立的 Ferry Plus 应用身份：io.github.yjcdon.FerryPlus，数据目录为 Application Support/Ferry Plus。
- 直接嵌入夸克官方登录页，与百度共用 WebView 容器和 Cookie 监听；短信、扫码和验证码交互由官方页面处理。
- 百度、夸克分别展示账号入口；原有百度登录与下载链路保留。
- 夸克登录信息保存在本应用钥匙串的 quark-login 条目，Cookie 按域名、路径与有效期使用；响应更新 Cookie 后写回同一条目。
- 启动恢复、手动验证和自动验证入口共用 QuarkAccountSession 与 QuarkClient。账号昵称不代替稳定 ID，网络失败不显示为校验成功。

当前没有接入夸克分享、转存和正式下载任务。完整功能范围仍按 [功能清单](features.md) 执行。

## 构建与运行

本机无需安装完整 Xcode。使用已有 Command Line Tools、Swift 工具链及 macOS 26.5 SDK：

```sh
bash Scripts/build-app.sh
```

产物是仓库下的 `.build/Ferry Plus.app`，仅含 arm64，可直接运行或拖到“应用程序”。不生成 DMG；需要传输时可将 App 压缩为 ZIP。

构建脚本默认使用 macosx26.5，其他具备完整组件的工具链可通过 FERRY_MACOS_SDK 显式选择 SDK。本机 macOS 27 SDK 缺少 SwiftUIMacros 插件，故没有使用其 SwiftUI 模块；工程中原有的 @Entry 已替换为等价的 FocusedValueKey 实现，保持菜单行为。

```sh
open ".build/Ferry Plus.app" --args --quark-login
```

也可在应用的“账号 → 登录夸克网盘”、侧边栏“账号与登录”，或设置的账号页打开登录窗口。在官方页面选择可用的登录方式，优先使用短信登录；应用在账号鉴权和钥匙串保存均成功后关闭登录窗口，并在账号菜单展示登录结果。

应用与已安装的 Ferry 使用不同标识和数据目录，不需要卸载原版。当前产物为本机临时签名构建，不代表正式发布流程已经完成。

## 登录后复用会话

以下命令运行同一个 App 内的验证入口，从同一个钥匙串条目恢复会话并读取账号、根目录，不输出 Cookie、二维码令牌或票据：

```sh
".build/Ferry Plus.app/Contents/MacOS/Ferry Plus" --verify-quark-session
```

输出 JSON 包含 provider（网盘来源）、authenticated（本次鉴权是否通过）、可用时的 accountID（稳定账号 ID）、nickname（昵称）、verifiedAt（验证时间）和 problem（失败原因）。通过时退出码为 0，未登录或验证失败时为 1。

后续接口验证使用同一客户端与会话服务，按 [任务清单](tasks.md) 的 T-21 推进。首次登录及需要重新认证时由用户完成官方验证；登录有效时复用会话。短信是否能自动读取及填写尚未验证，不作为现有能力；手机号与验证码不保存到代码或文档。

## 2026-10-23 验证记录

| 验证项 | 当前结果 |
| --- | --- |
| Swift 包构建 | 通过，包含 QuarkKit 和新增账号模型 |
| 原生 App 编译及签名 | 通过，生成 Ferry Plus.app；签名完整性检查通过 |
| 架构与最低版本 | Mach-O arm64，最低系统版本标记为 macOS 14；尚未在 macOS 14 真机运行 |
| 应用身份隔离 | 新 App 为 io.github.yjcdon.FerryPlus；已安装 Ferry 为 app.ferry.Ferry，数据目录分别使用 Ferry Plus 和 Ferry |
| 官方页面及容器 | 已确认官网提供登录组件；WebLoginSession 和 WebViewContainer 为两家共用，原有自制二维码与轮询代码已清除 |
| 未登录账号边界 | 账号接口的成功码及空账号数据不会被判作已登录；匿名请求冒烟验证通过 |
| 网页凭据边界 | 非夸克域 Cookie 被拒绝；合法域候选凭据序列化往返后保留域、路径与有效期，冒烟验证通过 |
| App 内自动验证入口 | 未登录时返回 authenticated=false、退出码 1；完成登录后新进程返回 authenticated=true、退出码 0 |
| Swift 测试 | 已定位本机 Command Line Tools 自带 Testing.framework 与宏插件，可用 `bash Scripts/test-packages.sh` 运行；未新增测试类，已迁移既有套件并在其中增加针对账号路由、撤销会话和写盘失败的断言 |
| 真实官方网页登录 | 用户已在官方页面完成登录，页面会话导入及账号、根目录鉴权通过 |
| 钥匙串写入及新进程恢复 | 通过。2026-10-23 23:49（Asia/Shanghai）独立 App 进程从钥匙串恢复凭据，账号身份校验及根目录读取成功；没有再次登录或导出 Cookie |
| 短信验证码自动读取及填写 | 尚未实现或验证；本次登录成功不代表能够自动读取“信息”App |

登录页面使用 [夸克官网](https://pan.quark.cn/)。账号与网盘接口参考 [Quark Downloader Pro 客户端](https://github.com/OP404OP/quarkdownloaderpro/blob/main/src-tauri/src/quark_client.rs)；参考实现不作为运行依赖，真实会话及错误状态以本次验证为准。
