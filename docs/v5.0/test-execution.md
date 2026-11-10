# Ferry Drive 5.0 实施与测试记录

按 [任务清单](tasks.md) 和 [测试用例](test-cases.md) 记录。各阶段未列出的用例待执行。Windows 实机用例进入第二阶段。

| 任务 | 第一阶段状态 | 验证 |
| --- | --- | --- |
| T01 | 基线已采集 | 固定 4.2.0 源码与实机样本，见[行为基线](baseline.md)。真实网盘文件树和操作确认按后续功能用例补采。 |
| T02 | 原型已验证 | Mac 上以 MyGo 自动化运行原生窗口，展开树表、输入中文、Esc 取消、Enter 确认。无窗口测试覆盖折叠及最小窗口布局。Windows x64 已交叉编译，实机 DPI 和原生输入法候选验收待对应阶段。 |

## T02 构建与验证

在 `desktop/` 执行 `go test ./...`、`go tool mygo vet` 和 `go tool mygo build -platform darwin/arm64,windows/amd64 -skip-dmg -skip-installer` 均通过。Mac App 使用临时签名，配置声明最低 macOS 14.0。产物位于 `.build/ferry-drive/`。安装验收由 T16 完成。

在 macOS 开发机上将固定版本 MyGo 的自动化插件仅链接到验证构建。原生元素树报告文本框、树形表格和弹窗，实际输入「测试文件」并确认后显示「已确认：测试文件」。这覆盖 C01 和 C65 的原型子场景。
