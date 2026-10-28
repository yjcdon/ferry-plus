# Ferry Plus 4.0 实施记录

状态：实施中。开始日期：2026-10-28。

用户已授权按任务清单实施、主代理与子代理分工、逐功能本地提交、最终 Review 和构建后 Computer Use 验证。构建产物只保留最新一份，旧产物移到废纸篓。尚未授权本版推送或发布。

## T01 实施基线

- 开始时源码 `main@63ff5052be15fb23b082cc7af66e6ef9669c8556`，业务源码未修改，待保存的变动仅为 4.0 设计文档。
- 本机安装 App 为 3.1，现有 Homebrew 管理及登录数据继续使用。开始时仓库根 `.build` 不存在，没有旧 App 构建产物需要清理。
- 现有环境为 Command Line Tools，SDK 26.5 与 27.0 可用；App 使用 `scripts/build-app.sh`，包测试使用 `scripts/test-packages.sh`。构建与测试在实施中记录实际命令和结果，不沿用历史通过数。
- 已核对入口：MainView 工具栏、ContentView sheet、应用菜单及快捷键、窗口级与行级拖放、UploadListView 云端定位、DemoData、AddLinkView 共享树。
- 目录浏览、账号状态及完整确认按设计迁移；公共 FileTree 保留分享兼容。专用测试目录将在真实验收时创建并记录准确身份，不操作其他云端内容。

## 执行记录

| 任务 | 当前事实 | 验证 |
| --- | --- | --- |
| T01 | 基线与调用方已核对，记录原数据目录 19 个 JSON 的摘要，不导出凭据 | `.build/v4-evidence/data-before.json`；初次编译与并行源码写入重叠被 Swift 中止，已在源码稳定后重新构建 |
| T03 | 百度目录分页拒绝重复、缺失列表及身份／类型／文件大小异常，保留正常多页、零字节和可缺省日期 | SDK 27.0，`scripts/test-packages.sh --scratch-path .build/v4-tests --filter DiskTests`：22 tests / 3 suites 通过，日志 `/tmp/ferry-v4-disk-tests.log`；现有测试文件扩展，未新增测试类 |
| T02、T04～T14 | 未完成；分工实施中 | 不将设计或源码推断记为通过 |
