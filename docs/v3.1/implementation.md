# Ferry Plus 3.1 实施记录

日期：2026-10-25。当前进入实施，3.0稳定版与用户登录／任务保持原位。设计见[技术方案](architecture.md)，顺序和完成标准见[任务清单](tasks.md)。

## 执行基线

主代理与子代理按独占文件分工，统一源码冻结后构建。源码、3.0发布ZIP和用户JSON摘要位于 `.build/v31-baseline/`；不导出凭据，不新建临时测试App。历史307项包测试只是3.0证据，不能冒称本轮新测通过。详细行为对照见[基线](baseline.md)。

## T00 行为与产物基线

已核对3.0源码归档的108项生产输入及发布ZIP摘要，整理19项候选合同与可复核的历史证据；原任务JSON只保存摘要，不导出凭据。当前源码修改前的可还原基线位于 `.build/v31-baseline/`，隔离样本来源与脱敏范围见 [baseline.md](baseline.md)。旧307项日志明确为历史证据，不算本轮测试。

基线完成后开始首批独占文件实施；实际代码与本轮验证将随各项功能的独立提交记录。

## T15 删除恒真无用属性

全库仅有定义的 canDownloadFromNetdisk 已删除。所有源码及DEBUG入口无残余引用；实际候选App上传入口、两家浏览入口仍可用。该项是无用代码清理，不声称性能提升。

本项纳入同一次源码冻结后的SDK26.5 Release App编译／固定签名及独立SDK27包测试，307项通过；日志 `.build/v31-wave1-{app-build,package-tests}.log`。主代理复核差异后，用实际App PID43467完成双账号、上传入口及两家上传／下载根目录加载，取消后任务仍0；本轮无云端写入，61份原用户JSON摘要无变化。界面及数据对照见 `.build/v31-wave1-ui/`。当前产品版本暂保留3.0，表示3.1优化候选的早期构建，未替换 `/Applications` 稳定版，最终3.1全功能验收由T21完成。

## T16 统一网盘固定根目录引用

新增 Provider.rootReference，百度仍为path=/、fsID=0，夸克仍为fid=0。四处上传／下载页面调用改用同一定义并删除两个重复方法，初始指定目录优先级与目录删除限制不变。实际候选两家上传页、下载页均成功从根目录加载。

本项纳入同一次源码冻结后的SDK26.5 Release App编译／固定签名及独立SDK27包测试，307项通过；日志 `.build/v31-wave1-{app-build,package-tests}.log`。主代理复核差异后，用实际App PID43467完成双账号、上传入口及两家上传／下载根目录加载，取消后任务仍0；本轮无云端写入，61份原用户JSON摘要无变化。界面及数据对照见 `.build/v31-wave1-ui/`。当前产品版本暂保留3.0，表示3.1优化候选的早期构建，未替换 `/Applications` 稳定版，最终3.1全功能验收由T21完成。

## T07 复用上传数值格式表达式

Int64.fileSizeText仅封装原ByteCountFormatter(.file)，替换7处同义表达式。保留下载.byteCount、上传rounded与下载截断、两种时间宽度差异。实际旧新表达式提取的179样例一致，来源与报告在 `.build/v31-formatting-validation/`。没有宣称格式统一后运行更快。

本项纳入同一次源码冻结后的SDK26.5 Release App编译／固定签名及独立SDK27包测试，307项通过；日志 `.build/v31-wave1-{app-build,package-tests}.log`。主代理复核差异后，用实际App PID43467完成双账号、上传入口及两家上传／下载根目录加载，取消后任务仍0；本轮无云端写入，61份原用户JSON摘要无变化。界面及数据对照见 `.build/v31-wave1-ui/`。当前产品版本暂保留3.0，表示3.1优化候选的早期构建，未替换 `/Applications` 稳定版，最终3.1全功能验收由T21完成。

## T08 收敛建目录回执接口

仅保留必需的(parent,name,onCreated)建目录closure，普通调用传空回调，两个正式工厂全部迁移；删除可选旧字段及返回后补回调fallback。Coordinator及AppModel业务方法签名不变。隔离实际SDK/Core的23项合同检查通过，包括前置失败POST0、准确回执先持久化、真实请求失败保留pending及检查点失败不重发；报告 `.build/v31-t08/`。本轮GUI只验证正常入口／目录加载，真实创建仍留最终T21，不冒称已经实际写云端。

本项纳入同一次源码冻结后的SDK26.5 Release App编译／固定签名及独立SDK27包测试，307项通过；日志 `.build/v31-wave1-{app-build,package-tests}.log`。主代理复核差异后，用实际App PID43467完成双账号、上传入口及两家上传／下载根目录加载，取消后任务仍0；本轮无云端写入，61份原用户JSON摘要无变化。界面及数据对照见 `.build/v31-wave1-ui/`。当前产品版本暂保留3.0，表示3.1优化候选的早期构建，未替换 `/Applications` 稳定版，最终3.1全功能验收由T21完成。

## T01 复用主列表渲染投影

同次body共享下载、上传过滤及可见排序，动作计算属性和跨await范围仍实时读取。720组旧新组合一致，过滤各3→1、排序2→1；不新增状态缓存。证据 .build/v31-t01/。实际GUI核对空列表的网盘／方向／分类及搜索，有任务范围的真实回归留T21。

本批源码冻结后 SDK26.5 Release App构建／固定签名通过，独立SDK27既有包测试307项通过；日志 .build/v31-wave2-{app-build,package-tests}.log。实际运行PID48872，双账号保留，无新凭据提示，用户61份JSON摘要不变；GUI记录 .build/v31-wave2-ui/。未替换Applications稳定版，最终3.1集成验收由T20／T21完成。

## T12 复用校验记录扫描基础

枚举与内容读取共享，查询fail-fast和inventory逐项错误保持独立。11组样本的load／matching／candidates／inventory共44项旧新结果一致，含正向匹配、坏JSON、未知版本及异常文件名。证据 .build/v31-t12/。实际设置显示60条校验记录，清理确认后取消。

本批源码冻结后 SDK26.5 Release App构建／固定签名通过，独立SDK27既有包测试307项通过；日志 .build/v31-wave2-{app-build,package-tests}.log。实际运行PID48872，双账号保留，无新凭据提示，用户61份JSON摘要不变；GUI记录 .build/v31-wave2-ui/。未替换Applications稳定版，最终3.1集成验收由T20／T21完成。

## T13 统一传输完成通知发送

两个内容生成入口共用发送尾部，保持请求ID、授权Task、内容、触发点及上下传原有取消检查差异。21组受控真实Swift Task旧新报告一致，弱引用释放检查通过，真实通知框架typecheck通过。证据 .build/v31-t13/；未将受控通知协作者冒称实际系统通知弹窗。

本批源码冻结后 SDK26.5 Release App构建／固定签名通过，独立SDK27既有包测试307项通过；日志 .build/v31-wave2-{app-build,package-tests}.log。实际运行PID48872，双账号保留，无新凭据提示，用户61份JSON摘要不变；GUI记录 .build/v31-wave2-ui/。未替换Applications稳定版，最终3.1集成验收由T20／T21完成。

## T18 统一产品版本配置来源

产品版本仅定义在Version.xcconfig，当前保留3.0；本机与CI读取相同脚本，Xcode两配置引用相同定义。CI tag不符明确失败，签名／bundle／构建号覆盖不变。26项隔离检查通过；工程plutil与脚本语法通过。真实本机固定签名Release构建通过；本机没有Xcode，未声称实际CI或Xcode构建通过。证据 .build/v31-t18/。

本批源码冻结后 SDK26.5 Release App构建／固定签名通过，独立SDK27既有包测试307项通过；日志 .build/v31-wave2-{app-build,package-tests}.log。实际运行PID48872，双账号保留，无新凭据提示，用户61份JSON摘要不变；GUI记录 .build/v31-wave2-ui/。未替换Applications稳定版，最终3.1集成验收由T20／T21完成。

## T19 CI复用打包入口

CI保留预期版本核对，改调现有package-app.sh，并将脚本实际ZIP／SHA路径传给Publish。Xcode构建及签名方式未变；本机打包脚本无改动。17项隔离检查通过，含真实固定签名arm64 App打包／SHA／解包逐文件一致、错误bundle／真实x86_64／损坏签名拒绝，合法ZIP不受失败输入影响。Publish使用gh替身验证参数，不触发远端发布。主代理已复核workflow差异、脚本输出契约及报告；证据 .build/v31-t19/。本项只有CI流程改动，无需额外App编译；不把本地CI shell验证冒称GitHub Actions运行通过。

## T03 收敛上传入口草稿

三个草稿属性合为不可变UploadDraft，presentUpload仍先检查已有sheet再整体替换，ContentView一次读取。240组旧新草稿／初始化结果一致；全库旧属性无引用。真实App默认百度、切夸克、取消后重开恢复默认且无旧文件，均正常。证据 .build/v31-t03/。

本批源码冻结后SDK26.5固定签名Release构建通过，独立SDK27现有307项测试通过，当前DEBUG Core构建及App完整类型检查通过，日志 .build/v31-wave3-{app-build,package-tests,debug-typecheck}.log。真实候选PID51260，两家目录可读，退出重开无凭据提示，原61份JSON摘要不变；GUI证据 .build/v31-wave3-ui/。无云端写入，未替换Applications稳定版；源码摘要 .build/v31-wave3-source-hashes.json，正式3.1版本及完整任务GUI验收由T20／T21完成。

## T04 收敛下载任务移除阶段

七处分散状态合为DownloadRemovalFlow，保留队列、逐项错误及处理／选择／导出阶段；不改Core归档和实时范围。720组旧新流程3294次状态／调用一致。另单列修复：上一确认关闭事件迟到时，必须当前阶段也确为未展示，才取消，避免误取消下一条确认；独立回归复现旧错并确认新流程保留下一确认。证据 .build/v31-t04/。本批GUI未创建任务；实际任务导出／放弃／移除留T21，不把受控流程冒称真实弹窗验收。

本批源码冻结后SDK26.5固定签名Release构建通过，独立SDK27现有307项测试通过，当前DEBUG Core构建及App完整类型检查通过，日志 .build/v31-wave3-{app-build,package-tests,debug-typecheck}.log。真实候选PID51260，两家目录可读，退出重开无凭据提示，原61份JSON摘要不变；GUI证据 .build/v31-wave3-ui/。无云端写入，未替换Applications稳定版；源码摘要 .build/v31-wave3-source-hashes.json，正式3.1版本及完整任务GUI验收由T20／T21完成。

## T05 按模式组织下载校验草稿

14处分散State合为IntegritySelection，手填／历史／清单草稿分组；导入文档与名称一起持有。保持模式切换保留草稿、上下文变化清依据且保留算法／刷新代次、取消及迟到回调规则。16个提取真实状态方法的旧新检查点一致。实际GUI切到JSON清单并打开导入面板、取消后回原页，未创建任务。文件面板选择样本时Open未可用，本批未验证实际导入成功／坏清单；这些仍在T21真实样本范围。证据 .build/v31-t05/。

本批源码冻结后SDK26.5固定签名Release构建通过，独立SDK27现有307项测试通过，当前DEBUG Core构建及App完整类型检查通过，日志 .build/v31-wave3-{app-build,package-tests,debug-typecheck}.log。真实候选PID51260，两家目录可读，退出重开无凭据提示，原61份JSON摘要不变；GUI证据 .build/v31-wave3-ui/。无云端写入，未替换Applications稳定版；源码摘要 .build/v31-wave3-source-hashes.json，正式3.1版本及完整任务GUI验收由T20／T21完成。

## T17 复用验证命令报告输出

共用sortedKeys编码和逐行输出，每次新编码器，原ISO8601调用显式保持；JSONSerialization错误报告不强改编码。19项编码／抛错检查及精确换行通过；展开helper后两个完整文件控制流与原版一致。Release实际--verify-quark-session退出0且authenticated=true，字段保留，DEBUG路径也完整类型检查通过。未重启长时间自然过期验证。证据 .build/v31-t17/及wave3-session文件。

本批源码冻结后SDK26.5固定签名Release构建通过，独立SDK27现有307项测试通过，当前DEBUG Core构建及App完整类型检查通过，日志 .build/v31-wave3-{app-build,package-tests,debug-typecheck}.log。真实候选PID51260，两家目录可读，退出重开无凭据提示，原61份JSON摘要不变；GUI证据 .build/v31-wave3-ui/。无云端写入，未替换Applications稳定版；源码摘要 .build/v31-wave3-source-hashes.json，正式3.1版本及完整任务GUI验收由T20／T21完成。

## T02 合并上传已加载目录上下文

账号、会话、目录引用和列表用一个LoadedDirectoryContext同步建立和失效。1169个提取生产方法的旧新检查点一致，覆盖最近目录恢复、迟到结果、取消/失败及按钮/冻结范围；另12组目录分支等价，单一空目录视图。实际候选两家根目录及夸克目录进入/返回正常。证据 .build/v31-t02/。

本批源码冻结后SDK26.5固定签名Release App构建与独立SDK27现有307项测试通过，日志 .build/v31-wave4-{app-build,package-tests}.log；完整生产输入摘要 .build/v31-wave4-source-hashes.json。真实候选已打开且目录读取正常，后续选择面板自动化遇窗口不可见/超时，诊断及未通过范围见 .build/v31-wave4-ui/observations.md。用户61份JSON摘要不变。本轮不写云端、不替换Applications稳定版；完整GUI验收不得因受控验证通过而省略。

## T06 整理上传明细独立辅助流程

12个分散State归入导出/源重定位/结果定位三个流程，不加全局busy。正常/并行与5种选源结果一致，100项分页及导出内容保持原规则。另单列增强：面板关闭不提前丢载荷，结果回调后释放；关窗重置后拒绝迟到回调；CloudRequest独立UUID区分同fileID两代请求，导出回调也捕获所属请求，不能清掉新流程。load及canRelocate保持字节一致。证据 .build/v31-t06/；真实任务导出/重定位及云端子sheet等待T21，不冒称已实际通过。

本批源码冻结后SDK26.5固定签名Release App构建与独立SDK27现有307项测试通过，日志 .build/v31-wave4-{app-build,package-tests}.log；完整生产输入摘要 .build/v31-wave4-source-hashes.json。真实候选已打开且目录读取正常，后续选择面板自动化遇窗口不可见/超时，诊断及未通过范围见 .build/v31-wave4-ui/observations.md。用户61份JSON摘要不变。本轮不写云端、不替换Applications稳定版；完整GUI验收不得因受控验证通过而省略。
