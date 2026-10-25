# Ferry Plus 3.1 行为与计数基线

日期：2026-10-25。用于 V31-T00 和后续 T20 对照。**这是已发布 3.0 的静态合同与历史证据整理，不是新一轮测试，也不是 3.1 验收结果。** 优化职责见 [技术方案](architecture.md)，19 项处置及完成状态见 [任务清单](tasks.md)。

## 1. 固定基线与证据

| 项目 | 固定来源与核对结果 |
| --- | --- |
| 源码 | `7e37e7f3e677eeb140ae1bbe33eedfde5a28778a`；业务源码基线为 `64aa672`。从 `.build/v31-baseline/source-3.0.tar` 读取，不用随后变化的工作区代替旧版 |
| 生产输入 | `.build/v31-baseline/source-hashes.json` 的 108 项与 tar 内容逐项 SHA-256 一致；这是本次静态核对 |
| 源码归档 SHA-256 | `08211f5afe9bba6e3a1d5a94d607e406d1120517dc9e634def7c24799434db4b` |
| 原 3.0 ZIP | `.build/v31-baseline/Ferry-Plus-3.0-arm64.zip`；本次重算 SHA-256 为 `66cc2a318298a793bee60da7a53e61d8fb0273b8e7f5f6f7383ac92ceed3cf31`，与保存清单一致。保留原包，不新建或启动 App |
| 历史包测试 | `historical-package-tests.log`：307 项、25 套件通过。沿用旧日志，不把它算作当前重新运行 |
| 历史覆盖证据 | 同目录已保存发布器／Coordinator 报告、实际 App 覆盖新旧内容下载结果与打包结果；分别保留模拟协议、实际网盘、实际 App 的范围 |
| 用户状态保护 | 父代理仅保存原 61 份用户 JSON 的哈希，不复制内容。本次未读取真实任务、Keychain 或登录数据，未恢复原大任务 |

本次静态核对结果及从 tar 提取的只读源码视图在 `.build/v31-baseline-audit/`；`baseline-check.json` 记录归档、ZIP 和输入一致性。这里的文件名都相对仓库根目录。

## 2. 19 项候选必须保持的原合同

以下均来自归档源码；没有运行次数、耗时或收益测量的项目，只记静态事实。

| 候选 | 原行为、错误与取消边界 |
| --- | --- |
| F01 列表投影 | 方向、网盘、搜索先筛选，再按分类取可见项；侧栏计数不预先套当前分类。按创建时间倒序，同时间按方向和 UUID 排序。确认后及跨 await 命令仍重取可见范围，不操作隐藏任务 |
| F02 上传上下文 | `loadedAccount / loadedSession / loadedDirectory` 必须同时匹配；加载或未登录不能提交。Tab／会话变化清空已加载上下文；请求快照和代次拒绝迟到结果，本地选择保留 |
| F03 上传草稿 | `presentUpload` 在已有 sheet 时拒绝覆盖；一次设置 provider、directory、files。全部网盘入口默认百度，目录入口带原目录，不能混用上次草稿 |
| F04 下载移除 | 队列逐项处理；可信依据自动归档，其他依据等待导出或明确放弃。取消停止后续项但保留已发生的错误；导出／归档失败保留任务，筛选改变只缩小范围 |
| F05 校验选择 | 初始无依据；切模式仅清错误、离开历史模式清所选候选、离开清单模式取消导入请求，保留其他模式草稿。选文件、换网盘／会话会重置模式、摘要、候选和清单，但保留算法选择。坏摘要／清单报错，历史依据不自动选定 |
| F06 上传明细 | 导出、源重定位、结果定位分别持有请求和错误；不是全局 busy。明细与导出每页 100 项，迟到结果校验请求及账号，重定位继续核对原摘要 |
| F07 数值展示 | 容量用 `.byteCount(style: .file)`；速度大于零才显示，未知 ETA 不显示为 0 秒。没有可信校验依据仍显示“未验证”，不改变完成条件 |
| F08 建目录 | 普通闭包与可选检查点闭包并存，两家正式工厂均提供后者。准确回执先保存，再检查会话；确定未发送与已发送未知结果分类不同，不能在合并接口时丢回执 |
| F09 覆盖回读 | 正常新内容完整读四次，详见第 3 节。原旧内容、独立快照与 claim 的检查有独立职责；已发布恢复仍实际回读，不能信旧 JSON 的成功状态 |
| F10 快照归档 | 稳定 ID 为上传文件 ID；保存账号、快照引用、原摘要、大小、原名、实际快照回读时间。后续阶段时间已不虚刷新，但相同记录仍反复写盘，详见第 4 节 |
| F11 检查点旧值 | `saveFile` 重读持久文件计算差值，文件先写、批次汇总后写；停止后的核对不改变执行意图。不能降低分片确认落盘频率或忽略 actor 跨 await 重入 |
| F12 校验记录扫描 | `matching / candidates` 遇坏记录抛错，缺目录返回空；`inventory` 按文件逐项报告失败并检查文件名。排序和容错合同不同，不能一律吞错 |
| F13 完成通知 | 共用一次授权 Task，但发送前重查系统权限；下载 ID 为任务 UUID，上传前缀 `upload-`。上传终态已保存且 worker 移除后通知；下载未验证文案和上传完成／失败／跳过计数保留。拒绝／发送失败不改任务结果 |
| F14 凭据接口 | 百度读取吞读取／解码错误，夸克读取抛错，代理读取降为空字符串；具体差异见第 5 节。接口收敛不默认授权新增弹窗或改变启动结果 |
| F15 恒真属性 | 应用 Swift 源码内 `canDownloadFromNetdisk` 只有恒真定义，没有调用；删除它不等于删除下载入口 |
| F16 根目录 | 上传页与下载页重复表达百度 `path=/, fsID=0`、夸克 `fid=0`；初始指定目录优先于根目录，根目录不可删除 |
| F17 验证命令 | 各分支已有独立报告与退出／信号／shutdown 顺序。`--verify-quark-session` 在 Release 可用；DEBUG 分支不因复用输出而进入 Release |
| F18 产品版本 | 本机 build 脚本写 3.0，工程 Debug／Release 各写 3.0；CI 从 tag 传入产品版本及运行号。统一产品版本不能改 Bundle ID、签名或覆盖 CI 构建号语义 |
| F19 打包 | 本机 `Scripts/package-app.sh` 与 CI 各自校验／压缩；ZIP 保留 App 根目录，另有 SHA 文件。复用后必须同步消费者路径，不能误上传旧包 |

## 3. 完整回读职责与静态计数

对象 A 为旧目标，S 为独立旧内容快照，B 为新暂存及发布后的同一准确新对象。下面计数以无重试、无冲突、完整成功为前提；一个“完整回读”会分成多次有界 Range，不等于一次 HTTP 请求。

| 次序 | 归档源码入口 | 对象及职责 |
| --- | --- | --- |
| 新 1 | `UploadCoordinator.verify` → `IntegrityService.verify` | 发布前 B；保存真实校验记录与进度，随后调用 `publishReplacement` |
| 新 2 | `UploadReplacementPublisher.publish` 的 `snapshotReady` 分支 | 按暂存名称、准确 ID、大小再读 B，对比原始 SHA 后才 claim |
| 新 3 | Publisher `confirmPublication` | 按原目标名称找到最终 B，核对准确 ID／大小并完整 SHA，保存 published 检查点 |
| 新 4 | Coordinator `publishReplacement` → `verify` | 最终 B；再生成校验记录，完成文件及准备授权清理 |

因此正常路径新内容为 **4 个文件长度的逻辑回读**，这是静态调用链计数，不是本次网络流量实测。`published` 恢复为 Publisher `verifyFinal` 加 Coordinator `verify`，通常两遍；`publishPending` 确认最终对象后也会再进入 Coordinator 校验。取消／只读核对、缺失对象及冲突路径须按实际经过的分支单独计数，不能一概套用四遍。

旧内容另计：`prepare` 采集 A 的全 SHA；`confirmSnapshot` 核验独立 S；发布前重新核验 S；claim 后核验实际被移动对象是否仍为 A。这四项不能直接列作重复 B 回读删除。A 与 B 长度可不同，不据新内容优化宣称总流量减半。

T09 对照必须记录实际对象、完整读取次数／字节、记录保存和授权释放；若删除某次读取，其结果接收方仍须取得本次真实 `actualDigest / verifiedAt / reference`，不能复制期望值构造“自己等于自己”的记录。跨进程恢复仍需本次完整核验。

## 4. 重复 IO 的原序列

来源：归档 `UploadCoordinator.swift` 的 `received`、`saveFile`、`replacementCheckpoint`，以及 `UploadStore.swift` 的公开读取／保存与 `publishedJob`。以下为**成功普通路径的函数级 JSON 读写计数**，不包含 OS 缓存、stat、失败重试，也没有新做 IO 测量。

- 一次 `received` 先 `store.loadFile`，读取权威 manifest 与文件；随后 `saveFile` 再读取同一 manifest 与旧文件求差值，再 `store.saveFile` 核对 manifest 后写文件；`persistJob → saveJob` 又读原 manifest 后写新汇总。已发布成员不变时，合计 **manifest 读 4 次、文件读 2 次、文件写 1 次、manifest 写 1 次**。
- 单独一次 Coordinator `saveFile` 不含调用者预读时，合计 manifest 读 3 次、文件读 1 次、两份元数据各写 1 次。其他调用方可能已加载原文件，但能否复用需证明跨 await 的旧值仍有效，不能按这张表直接省掉权威检查。
- `replacementCheckpoint` 先加载文件、调用上述 `saveFile`，再无条件调用 `IntegrityStore.save`：只要 snapshotObject、originalSHA256、snapshotVerifiedAt 齐全，便验证／编码同一快照记录并原子写一次，即使此阶段没有新回读。稳定 ID 防重复条目，不防重复写。
- `snapshotVerifiedAt` 已只在两处实际快照全读成功后更新；后续检查点沿用真实旧时间。旧状态缺此字段时不补造时间，原记录保持不变。F10 只能省相同证明的写入；缺失、坏记录或之前保存失败仍须补齐归档，不能以“存在一个文件”判断成功。
- 原子性是“每文件检查点先保存，批次聚合随后保存”，不是跨文件事务；失败可能留下新文件／旧汇总，恢复逐文件重建。未知版本、权限和坏 JSON 必须仍显式失败并保留原数据。

## 5. 数据、凭据和可见变化边界

- 数据根仍为 `Application Support/Ferry Plus`；下载 `jobs.json / Downloads/`、上传 `Uploads/<jobID>/job.json / Files/<fileID>.json`、校验 `Integrity/<ID>.json`。Upload／Integrity 外层为 `{version:1,value:…}`，未知版本拒绝；任务 ID、账号、路径、分片、暂停意图和校验来源不因优化迁移。
- 设置仍是 UserDefaults 的 `settings` 原始 Data；`settings.before-v3` 和已有元数据升级备份保持。3.1 本轮不新增 JSON 版本、数据库或凭据迁移。
- 凭据 service 取 Bundle ID，已发布 App 为 `io.github.yjcdon.FerryPlus`；generic password 账号键如下。这里只核对源码契约，没有读写钥匙串。

| 条目 | 不存在 | 读取／解码失败 | 保存／删除失败 |
| --- | --- | --- | --- |
| `baidu-login` | nil | `load()`／解码 `try?` 降为 nil | 保存抛错；登出 `deleteChecked` 抛错，不能只清空内存 |
| `quark-login` | nil | 读取与解码均抛错 | 保存、删除均抛错 |
| `socks-proxy` | 空字符串 | 读取／UTF-8 失败降为空字符串 | 非空保存抛错；空密码使用 unchecked delete，删除失败被忽略 |

`loadChecked` 只把 `errSecItemNotFound` 当未保存，其他错误保留 OSStatus；新增条目使用 AfterFirstUnlock。上述差异是 F14 的原可见错误合同，改成统一错误提示是单独行为修正，不能混作等价优化。单一格式化入口、根目录值、草稿值对象和构建配置本身不授权改变交互、文案或删除确认。

## 6. 隔离样本与 T20 复用

只读整理既有自建模拟样本，没有运行恢复或网络。来源及逐文件哈希在 `.build/v31-baseline-audit/fixtures/provenance.json`。

| 样本 | 保存内容与限制 |
| --- | --- |
| 完成 | 从历史 `replacement-coordinator-validation/run-88B3159C-…/normal/Integrity` 复制 3 条 verified 记录到 `fixtures/completed-integrity/`；账号固定为 `offline-coordinator`，摘要与期望一致，无授权字段。原完成任务已被历史测试移除，不能声称保存了该任务完整恢复包 |
| 暂停 | 复制 `v3-metadata-resource-validation/n-1000/uploads` 的一批 1000 文件元数据到 `fixtures/paused-metadata/Uploads/`；账号 `metadata-resource-fixture`，queued＋isPaused=true，500 项 skipped，无源正文、书签或原生授权。适合解码／计数／零调度对照，不允许恢复发送 |
| 待核对 | 记录历史 `replacement-coordinator-validation/run-88B3159C-…/unknownPublish` 的 job／file 原路径与 SHA、failed／publishPending 状态及准确 ID。原 file 含本地 bookmark 和模拟 nativeSession，**不复制这些字段或原始文件**；保留白名单来源摘要和对应 fake Backend／入口源码，未来可在隔离 Store 重建，不把它当可直接解码的完整副本 |

这些 fixture 属于早期隔离验证，不能冒称由本次 3.0 归档重新生成，也不能加载到正式 App 数据目录。T20 可用归档源码与候选分别读取相同隔离副本；若需要完整发送／恢复样本，先在 scratch 重建 fake Backend 和专用源文件，不借用真实凭据或用户暂停任务。动态读取／写入计数、故障注入和候选收益仍待各自任务实施时记录。
