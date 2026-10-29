# 4.1 侧栏与半屏窗口尺寸修复

日期：2026-10-29。关联 T06、T07，C01—C03、C20。

主窗口侧栏与详情采用 balanced 分栏，在当前可用空间内分配尺寸。侧栏显示后的窗口观察值曾为 819 点；后续实际窗口诊断确认 contentMinSize 为 640 × 452 点，contentFitting 为零，819 点属于当时观察的窗口尺寸。

主窗口显式采用 balanced 分栏样式，侧栏出现时由详情腾出空间。详情列声明 320 点最小宽度、640 点理想宽度和弹性扩展，窗口总体沿用 640 点最小宽度。文件表格继续在自身区域横向滚动；任务详情沿用空间不足时收起的规则。

当时搜索占位文本裁切的独立原因已定位为工具栏实际搜索控件的内距，修复与测量见[搜索尺寸记录](search-sizing-implementation.md)。

已检查全部 NavigationSplitView 调用，本次修改集中于 MainView 的主窗口。文件及传输两种页面共用该列尺寸规则，业务操作、导航状态和列宽偏好继续沿用现有实现。

依据：[Apple balanced](https://developer.apple.com/documentation/swiftui/navigationsplitviewstyle/balanced) 说明该样式在显示前导列时缩小详情；本机 SwiftUI SDK 声明其从 macOS 13 可用，满足 macOS 14 目标。

验证：语法解析、差异空白检查及完整 App 源码快照的 macOS 14 目标类型检查通过。实际半屏、侧栏切换、搜索可达性由整合构建继续验收。
