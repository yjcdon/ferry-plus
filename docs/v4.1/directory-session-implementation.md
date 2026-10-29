# 4.1 文件浏览会话失效同步

日期：2026-10-29。关联 T11、T14，C39。

## 实现

文件页的目录树读取错误接入现有 `AppModel.noteError(_:from:)`。根目录读取、目录展开及恢复展开均由同一 FileTree 错误回调传递原始错误；目录初始化阶段错误也进入该入口。

入口携带创建本次目录树时的准确 Netdisk 实例。AppModel 先核对它仍是所属网盘当前实例，再按真实的 BaiduError.loginExpired 或 QuarkError.loginExpired 更新对应会话。其他错误保留原目录反馈。已有百度与夸克失效处理分别撤销自身会话并更新共享账号状态。

FileTree 回调弱引用 AppModel，沿用现有目录请求代次和账号校对。分享页继续使用同一 AppModel 错误入口，账号服务与凭据存储沿用原实现。

## 验证

已检查全部调用方：DirectoryBrowserState 由 WorkspaceState 创建两份，文件页调用 load；分享页原有 noteError 调用保持。旧实例的迟到错误由 AppModel 实例比较隔离，两家网盘按 Provider 分别处理。

- 使用 SDK 26.5、`arm64-apple-macos14.0`、Swift 6 与项目相同隔离选项对全部 App 源文件执行 `swiftc -typecheck`，通过。
- 运行现有 AccountTests 筛选，10 个测试、3 个套件通过，覆盖账号切换隔离及过期凭据解析；此处结果验证既有底层合同。
- C39 的实际失效、页面／菜单／设置同步及重新登录恢复由主代理统一执行并归入 test-execution.md。
