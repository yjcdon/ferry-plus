# 4.1 应用状态与目录刷新简化

日期：2026-10-29。

- 批量下载操作统一沿用 `jobs(in:allowing:)` 筛选和 `perform(_:on:)` 执行，清理原先闲置的四个暂停／继续包装方法。
- 下载确认继续调用普通 `AppModel.addNetdiskJob`，清理闲置的摘要绑定 App 桥接；FerryCore 的绑定接口及已有测试保留。
- 百度登录应用流程在替换客户端前设置一次账号，后续凭据与登录状态更新沿用现有顺序。
- 目录刷新在展开状态恢复完成后生成一次节点数组，复用到选中恢复和准确对象定位；会话、账号、目录与请求代次核对保持原流程。

验证：全仓受版本管理的源码、DEBUG 验证、菜单和脚本调用已核查；macOS 14 目标全 App Debug 静态类型检查通过，日志 `/tmp/ferry-v41-app-model-simplification-typecheck.log`。实际 App 验收由统一重建流程继续完成。

## 手动并发设置

会员预设入口收敛后，清理 `ConcurrencyPreset` 及对应匹配／应用 API。并发文件数、两家每文件连接数、上传设置与持久化字段沿用现有手动配置；下载配置继续按两家连接数的较大值建立分片能力，并执行总连接预算。既有 `JobModelTests` 覆盖两家连接投射、超预算限幅和设置编码往返。

验证：全仓源码、DEBUG 验证与脚本中的预设引用已清理，`swift test --package-path Packages/FerryKit --filter JobModelTests` 通过 25 项测试。日志 `/tmp/ferry-v41-manual-concurrency-tests.log`。
