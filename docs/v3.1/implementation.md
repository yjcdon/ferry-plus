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
