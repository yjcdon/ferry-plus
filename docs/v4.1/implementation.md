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
| T01 基线 | 部分完成 | 安装版本、构建与资源基线已记录；18 份原 Integrity 内容一致；原任务及设置的逐字段旧快照缺口见 compatibility-evidence.md |
| T02 原型 | 集成验收中 | 原生表格及实色界面已构建；表头排序、日期、勾选、展开和两条列边界拖动已实测，其他系统运行继续单列 |
| T03—T05 文件树迁移 | 代码已提交，交互验收中 | file-list-implementation.md、native-list-review.md |
| T06—T07 窗口和工具栏 | 代码已提交，交互验收中 | navigation-implementation.md、toolbar-implementation.md；系统半屏实测通过 |
| T08 任务行 | 代码已提交，交互验收中 | transfer-row-implementation.md |
| T09 详情与历史归档 | 代码已提交，交互验收中 | inspector-implementation.md、archive-implementation.md |
| T10—T11 面板和反馈 | 代码已提交，交互验收中 | file-panel-implementation.md；新建非法字符与双网盘上传面板已实测 |
| T12 设置 | 代码已提交，待完整界面验收 | settings-implementation.md |
| T13 实色与辅助功能 | 代码已提交，交互验收中 | solid-surface-implementation.md |
| T14 兼容与清理 | 部分完成 | 317 个包测试通过；分页、归档、观察生命周期已审查；分享行闲置扩展已清理，原任务兼容证据范围单列 |
| T15 双网盘验收 | 部分完成 | 两家回环摘要、同名策略、分享下载及批量回收站已实测；原生列表与资源补充记录见 test-execution.md；拖放等子场景继续覆盖 |
| T16 发布交付 | 已发布 | README／CHANGELOG、验收记录及 Homebrew 已同步；主分支与 v4.1 标签已推送，公开 App ZIP 与摘要已上传 |

## 发布准备清单

| 项目 | 当前结果／发布动作 |
| --- | --- |
| 版本与平台 | Config/Version.xcconfig 为 4.1；实际 App 为 4.1、arm64，最低 macOS 14.0 |
| 应用身份 | io.github.yjcdon.FerryPlus；固定证书签名，codesign --verify --strict 通过 |
| 最新产物 | .build/Ferry Plus.app；.build/dist/Ferry-Plus-4.1-arm64.zip 及对应 .sha256 |
| 打包一致性 | ZIP 摘要检查通过；主程序、Info.plist、签名资源表和三份图标资源逐文件摘要与实际 App 一致 |
| 旧产物 | 前一份 ZIP／摘要已移到废纸篓，构建目录保留最新 App 和发布产物 |
| 对外说明 | README／CHANGELOG 已列出 4.1 发布改动及实际证据入口 |
| Homebrew | Casks/ferry-plus.rb 已更新为 4.1，摘要与最终公开 ZIP 一致；下载地址沿用版本模板 |
| 发布与本机更新 | 用户已要求本机安装，/Applications/Ferry Plus.app 已更新为当前 4.1 构建；本次按用户指令推送并发布 v4.1 |

当前包体对应功能源码 `83c0230`，版本 4.1，ZIP 为 3937529 字节，SHA-256 为 `2f27461d7f8aea1536d256099089eeb4c64a3be8dbca597ddfa1dabee5dc2504`，六个有效文件与本机安装 App 一致。现有包测试 317 项通过；专项验证见 test-execution.md。

## 本机安装

2026-10-29，按用户要求将 `3b39c72` 构建安装至 `/Applications/Ferry Plus.app`，替换原 4.0 应用。旧 App 已移到废纸篓；安装版主程序与最新构建逐字节一致，固定签名检查通过。实际启动进程来自 `/Applications`，百度与夸克账号菜单均保留已登录账号，目录和任务继续读取原数据。随后已更新为 83c0230 构建，侧栏边距实测通过。

## 4.1 发布交付

2026-10-29，用户要求推送并发布 Release。功能代码以 83c0230 为基线，发布提交同步文档；本次标签推送后 GitHub Actions 尚未生成构建任务，改用已验收的本机签名 arm64 App 发布 ZIP 和 SHA-256；Homebrew 使用同一公开产物摘要。此前本机构建的包体记录用于本机验证，公开交付产物以 Release 下载及摘要为准。

已实现任务见各专题实施记录。完整包测试 317 项通过，补充传输状态专项见验收执行记录。正确内容重新选源完成链路、拖放细分、辅助功能和其他系统实机继续列为待验证子场景；此前表格中的“验收中／部分完成”表示对应全量用例覆盖程度。

发布地址：[Ferry Plus 4.1](https://github.com/yjcdon/ferry-plus/releases/tag/v4.1)。源码标签固定发布时版本，主分支继续同步安装定义和交付记录。
