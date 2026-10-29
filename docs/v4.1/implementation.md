# 4.1 实施记录

## 基线

- 开始实施日期：2026-10-29；功能基线 `31077ec`，方案提交 `e6c74db`。
- 本机已安装 4.0，App 约 12 MB；发布 ZIP 约 3.7 MB；本次沿用 Scripts/build-app.sh 的 arm64、macOS 14 部署目标与固定证书签名。
- 当前系统报告 macOS 27.2，新增 API 按部署目标检查；macOS 14/26 实机运行证据另行记录。
- 当前 .build 只保留一份 App；后续重建覆盖此路径，过时发布产物移到废纸篓。
- Computer Use 首次检查确认 Mac 当前锁屏。实现与构建继续推进，界面验收在可操作桌面后执行。

## 任务状态

| 任务 | 状态 | 证据 |
| --- | --- | --- |
| T01 基线 | 进行中 | 已核对安装版本、产物路径、脚本与当前系统；资源比较及升级数据核对在集成验收记录 |
| T02 原型 | 集成验收中 | 原生表格及实色界面已构建；表头排序、日期、勾选、展开已实测，列拖动继续定位 |
| T03—T05 文件树迁移 | 代码已提交，交互验收中 | file-list-implementation.md、native-list-review.md |
| T06—T07 窗口和工具栏 | 代码已提交，交互验收中 | navigation-implementation.md、toolbar-implementation.md；系统半屏实测通过 |
| T08 任务行 | 代码已提交，交互验收中 | transfer-row-implementation.md |
| T09 详情与历史归档 | 代码已提交，交互验收中 | inspector-implementation.md、archive-implementation.md |
| T10—T11 面板和反馈 | 代码已提交，交互验收中 | file-panel-implementation.md；新建非法字符与双网盘上传面板已实测 |
| T12 设置 | 代码已提交，待完整界面验收 | settings-implementation.md |
| T13 实色与辅助功能 | 代码已提交，交互验收中 | solid-surface-implementation.md |
| T14 兼容与清理 | 审查修复中 | 314 个现有测试通过；分页读取与观察生命周期已审查 |
| T15 双网盘验收 | 进行中 | 夸克三文件回读摘要一致；百度收尾与回读继续验证 |
| T16 发布准备 | 待验收收尾 | 根据实际完成结果同步 README、版本和交付清单 |
