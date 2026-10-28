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
| T05 | 精简上传确认保留本地文件选择／拖入、权限、同名策略、预检查和固定账号会话；移除面板内目录浏览 | 最新整体 App 编译及固定签名通过；实际选择器与传输验收待执行 |
| T07 | 精简下载确认保留本次保存目录、手动摘要、历史记录、JSON 清单及取消／会话失效隔离；普通目录依旧入队后枚举 | 整体 App 编译通过；实际四模式与下载验收待执行 |
| T04、T08 | 常驻列表复用 FileTree，按需展开、同级排序、根级搜索、勾选去重、路径导航；新建冻结上下文，删除使用各自准确父目录 | 整体 App 编译通过；实际百度根目录读取成功；子树、跨层删除和两家目录操作待验收 |
| T02、T06、T09～T14 | 未完成；分工实施中 | 不将设计或源码推断记为通过 |

包回归：SDK 27.0，`scripts/test-packages.sh --scratch-path .build/v4-tests`，310 tests / 25 suites 通过，日志 `/tmp/ferry-v4-package-tests.log`。最新整 App 使用 SDK 26.5 和固定证书构建，日志 `/tmp/ferry-v4-build.log`，已由 Computer Use 启动 `.build/Ferry Plus.app`，百度登录复用并列出根目录。早期 MainView 类型检查超时已通过按职责拆分 View 构造表达式解决，最终构建通过；真实交互验收继续进行。
