# 本地文件上传可行性验证

验证日期：2026-10-24。基线版本：Ferry Plus 2.0；本次只验证协议和现有会话，不增加上传界面或修改已发布 App。百度分片回读经专项定位后，已完成完整内容一致性校验，四种组合全部通过。

## 验证方式

独立签名验证程序通过应用现有 CredentialStore、QuarkCredentialStore 读取钥匙串，复用保存的网页登录 Cookie。没有使用 OAuth、重新登录或导出凭据。验证程序与安装版使用相同应用标识和签名证书，不接入用户任务列表。

每家生成新的随机数据：4096 字节的小文件和 20971643 字节的分片文件。大文件实际分为 6 片，前 5 片各 4194304 字节，最后一片 123 字节；随机样本避免以秒传代替实际上传。流程包括账号身份核对、创建唯一测试目录、上传、合并、远端目录大小核对、下载回读 SHA-256 比较，以及只将本次目录移入网盘回收站并核对目录已消失。

原有云端文件和本地文件未用于上传样本。验证程序、参考源码及原始脱敏日志保留在本机 `.build/upload-probe/`、`.build/upload-probe-v2/` 和 `.build/upload-probe-reference/`，不打入发布包。

## 上传协议

- 百度复用现有 Cookie，校验后取得当前 bdstoken。调用 `/api/precreate`，向 `/rest/2.0/pcs/superfile2` 实际上传各片并核对分片 MD5，最后调用 `/api/create` 合并，再通过既有目录与下载接口核对结果。
- 夸克复用现有 Cookie，依次调用 `/file/upload/pre`、`/file/update/hash`、`/file/upload/auth`。根据服务端返回的分片大小向对象存储上传，记录每片 ETag，完成分片合并后调用 `/file/upload/finish`。对象存储只接收此次上传签名，不接收网盘登录 Cookie。

这两条是网页登录会话的上传路径。官方开放平台和官方工具的 OAuth 授权路径与此不同，不能把本次结果扩写为已接入 OAuth。

参考：[百度开放平台上传流程](https://pan.baidu.com/union/doc/3ksg0s9ye)、[BaiduPCS-Go 上传实现](https://github.com/qjfoidnh/BaiduPCS-Go/blob/main/baidupcs/prepare.go)、[OpenList 夸克上传实现](https://github.com/OpenListTeam/OpenList/blob/main/drivers/quark_uc/util.go)、[夸克官方上传工具文档](https://github.com/quark-clouddrive/quarkclouddrive_offical/blob/main/skills/quarkclouddrive/references/file-upload.md)。

## 当前结果

| 网盘 | 样本 | 实际上传 | 服务端合并与目录核对 | 下载回读 |
| --- | --- | --- | --- | --- |
| 百度 | 4096 字节 | 1 片，每片 MD5 核对通过 | 通过 | SHA-256 一致 |
| 百度 | 20971643 字节 | 6 片，每片 MD5 核对通过 | 通过，远端大小一致 | 81 段范围回读完成，逐字节比较及 SHA-256 一致 |
| 夸克 | 4096 字节 | 1 片 | 通过 | SHA-256 一致 |
| 夸克 | 20971643 字节 | 6 片 | 通过 | SHA-256 一致 |

**结论：两家现有网页登录状态都可以用于本地文件上传，不必为这条路径新增 OAuth 授权。小文件与分片文件四种组合均已完成上传、合并及完整内容一致性验证。** 百度首轮回读遇到的 403 和超时经后续专项定位后已解决，具体对照与最终校验见下文。

首轮夸克分片文件 SHA-256：`ae84172edabc892da433f114667d231f4349311e0e61948e645619245ae7c2ee`。所有轮次的专用测试目录均已移入网盘回收站并确认从原位置消失，没有永久清空回收站。定位过程中增加过一轮双网盘复测和一轮仅百度分片复测；夸克复测两种样本仍通过完整回读。百度专用复测清楚记录了 `merged`、`remote_size_verified`，随后首个 CDN 回读返回 403，备用地址等待超过 4 分钟后主动终止；之后由清理程序先核对目录身份和内容范围，再完成本轮目录清理。

本机脱敏证据：

- `.build/upload-probe/progress.jsonl`：首轮两家的上传、回读及清理结果。
- `.build/upload-probe/baidu-multipart-followup.jsonl`：定位复测，含百度下载请求超时、两家清理，以及夸克分片回读成功。
- `.build/upload-probe/baidu-instrumented.jsonl`：百度专用复测，确认 6 片 MD5、合并、远端大小和回读 403 所在阶段。
- `.build/upload-probe/final-cleanup.jsonl`：主动终止备用地址等待后，核对专用目录名称、文件名称及大小，再删除并确认原目录消失。

首轮按“上传后完整下载并核对 SHA-256”的严格标准为 3/4 通过；下述专项验证补齐百度分片内容校验，当前有效结论更新为 4/4 通过。

## 百度分片回读定位

针对同一份 20971643 字节随机样本完成对照，不把目录大小相同当作内容校验。样本只上传一次，后续复用同一远端文件与本地原始数据；本地记录目录身份和原始 SHA-256，失败后可以继续核对。

### 403：请求缺少 Range

在 `matrix.jsonl` 的同一 CDN 下载地址上，`Range: bytes=0-4095` 返回 HTTP 206 和正确的 4096 字节；去掉 Range 后立即返回 HTTP 403，JSON 错误为 `error_code=31326`、`user is not authorized, hitcode:104`。`timeout-matrix.jsonl` 在 `allall01.baidupcs.com` 和 `xa-cm20.baidupcs.com` 再次得到相同对照。

因此，本次 403 的触发条件已经定位为这些 CDN 对整文件请求的拒绝，不能直接解释为网页登录失效或上传内容损坏。其他节点可能接受整文件请求，不能假定所有节点的响应一致。

### 超时：响应体正在传输时达到总时限

受控测试给请求设置 20 秒总资源时限，记录 URLSession 分阶段指标。`xad0-cm.baidupcs.com` 的整文件请求在约 20.245 秒内已收到 1965101 字节，随后返回 NSURLErrorDomain -1001；该节点 4 MiB 范围请求在约 20.279 秒内收到 1457111 字节，同样到时取消。其他两个节点的 4 MiB 请求也在传输约 933888 字节后被总时限取消。

这些请求的连接、TLS 和首包等待都在一秒以内，超时发生于持续接收内容的阶段。实测链路约为每秒 45～95 KiB，20 MiB 整文件可能耗时超过旧探针的 240 秒总资源时限；不能把这种超时作为文件上传失败的证据。

### 验证方式调整

读取请求显式携带 Range 和 `Accept-Encoding: identity`。每段 256 KiB，最多并发 4 段，每个请求总资源时限 60 秒。逐段核对 HTTP 206、Content-Range、实际长度及原始字节，再按顺序保存本地检查点，最后计算全文件 SHA-256。全程复用现有登录，使用接口下发的动态 CDN 地址。

正式 DownloadKit 引擎原本就会发送 Range；本次调整针对独立验证程序，不改变上传界面或已发布 App。

### 最终内容一致性结果

2026-10-24 17:29（Asia/Shanghai），完整回读 20971643 字节。全文件共 81 个 256 KiB 范围（最后一段 123 字节），逐段校验后写入本地；中途切换为最多四段并发，先校验已保存前缀再继续，没有再次上传样本。最终记录 `verified`，随后清理专用云端目录并确认原位置已不存在，验证进程退出码为 0。

原始文件和完整回读文件 SHA-256 均为：

```text
c5bee9ac7f6118d7043171628a9f61bcde0cc1a870c8065e6d65642be3e48697
```

额外使用系统 `cmp` 逐字节比较，退出码为 0；`shasum -a 256` 分别计算本地原始文件和回读文件，也得到上述同一值。

本机证据位于 `.build/baidu-readback/`：

- `matrix.jsonl`：同一下载地址有 Range 返回 206，无 Range 返回 403／31326。
- `timeout-matrix.jsonl`：三个 CDN 节点的范围对照、响应体接收字节数与总时限取消指标。
- `diagnostic.jsonl`：原始样本的六片上传、合并、上传前 SHA-256 和早期短时限回读诊断。
- `verified-readback.jsonl`：较小范围单路回读和保存检查点。
- `final-readback.jsonl`：同一样本从已验证检查点继续、完整 SHA-256 校验及云端清理确认。
- `receipt.json`：本次专用目录身份和原始样本 SHA-256；不含登录凭据。
- `sample.bin`、`downloaded.bin`：原始随机样本和完整回读副本，仅用于本地复核，不提交或打入发布包。

## 后续实现边界

现有账号、代理、目录浏览和账号归属已用于 3.0 的正式引擎、检查点及上传窗口。实现与 App 验收以 [3.0 执行记录](v3/implementation.md) 为准；本文的协议探针不替代暂停恢复、空间不足、会话失效及部分成功的完整产品验收。

## 正式接口同名冲突实测

2026-10-24，使用正式客户端和原登录，在唯一专用目录分别验证“已有同名”和“预查为空后另一写入先占用名称”两种场景，每次碰撞前后按原对象 ID 回读 SHA-256。

| 网盘 | 两种场景的实际结果 | 原文件 |
| --- | --- | --- |
| 百度 | `rtype=0` 的准备请求返回 `alreadyExists`，没有发布新文件 | fsID、内容 SHA-256 均保持 |
| 夸克 | 服务端自动另存为 `existing(1).bin`／`list_then_race(1).bin`，新 fid 与预分配 fileID 相同 | 原 fid、内容 SHA-256 均保持 |

正式策略据此处理：百度仅在明确名称冲突且尚未保存会话时有限重选名称；夸克以准确 fileID 和大小确认产物，按查询到的实际名称展示，不因自动改名误判上传失败。此结果验证本次两种冲突路径，不能作为条件版本替换或安全覆盖的证明。

### 安全覆盖的能力边界

安全替换所需的准确对象操作、原子冲突处理及对象版本语义尚未证实。不能用先查后改代替原子条件；也不能仅因没有找到 CAS 就断言所有备份发布协议都不可行。

百度官方 SDK 的 [Rename](https://github.com/baidu-netdisk/baidu-drive-sdk-go/blob/main/baidudriver/api/file_manager_rename.go) 按 path／newname 操作，[Move](https://github.com/baidu-netdisk/baidu-drive-sdk-go/blob/main/baidudriver/api/file_manager_move.go) 有 ondup=fail，但这些材料没有证明源 fsID 或内容版本可作为操作前置条件。路径预查后重命名仍有并发窗口。

夸克的 [OpenList 适配实现](https://github.com/OpenListTeam/OpenList/blob/main/drivers/quark_uc/driver.go) 按 fid／file_name 重命名；[官方文件操作文档](https://github.com/quark-clouddrive/quarkclouddrive_offical/blob/main/skills/quarkclouddrive/references/file-ops.md) 没有给出内容版本条件写入合同。后续实测已证明本次重命名对现有同名明确拒绝，但对象 ID 绑定不可变内容版本仍未证明。

若能证明准确旧 ID 改备份、新 ID 原子不覆盖发布、失败时不覆盖恢复，可实现保留旧内容的可恢复替换。但原名称可能短暂空缺，且不能天然拒绝执行期间变化的旧版本。这不代替 V3-T09 约定的并发版本保护；V3-T09 保持未完成。

证据 `.build/v3-collision-probe/run.jsonl`。两家专用目录 `FerryPlus-V3-Collision-66638F3C-952F-4FB5-BC75-6FA8F6D03E86` 均按目录 ID 核对后移入回收站，并确认原位置消失。

正式实现继续使用 Swift 原生请求，不引入 Node 或 Go 运行时。按分片读取文件并限制并发；本次探针为有界样本使用内存数据，不作为正式大文件内存策略。

### 2026-10-25 重命名及对象版本能力复验

复用当前登录，仅在全新随机专用目录使用 4096 字节不同内容样本，操作前保存意图，操作后按对象身份完整回读 SHA-256。

| 探针 | 实际结果 | 可确认的边界 |
| --- | --- | --- |
| 百度将 A 改为已存在的 B | `/api/filemanager` 返回 errno 12、子项 -8；A/B 的 fsID、名称、完整 SHA 均不变 | 本次 rename 明确拒绝同名覆盖，不提供源内容版本条件 |
| 夸克将 A 改为已存在的 B | `/file/rename` 返回 HTTP 400／23008，明确存在同名；A/B 的 fid、名称、完整 SHA 均不变 | 本次 rename 明确拒绝同名覆盖，不证明 fid 内容不可变 |
| 百度 PCS `ondup=overwrite` 同名内容更新 | HTTP 200，新内容完整 SHA 匹配，fsID 改变；旧 ID 不在当前目录 | 只证明该写入路径更换对象身份，没有证明旧 ID 内容仍能读取或恢复 |

百度官方 [预创建](https://github.com/baidu-netdisk/baidu-drive-sdk-go/blob/main/baidudriver/api/upload_precreate.go) 和 [合并](https://github.com/baidu-netdisk/baidu-drive-sdk-go/blob/main/baidudriver/api/upload_create.go) SDK 有 `is_revision=1` 版本管理参数；其 OAuth 合同不能直接套入现有 Cookie 接口，也不等于条件版本替换。夸克官方分发 1.0.25 的 `file-rename.md` 提供批量名称撤回，但没有内容版本 CAS；GitHub 对应文件 404 不代表分发包缺少该文档。

证据 `.build/v3-overwrite-capability-audit/{report.md,p1/journal.jsonl,p4/journal.jsonl}`。三个专用目录均已核对身份后移入回收站，未永久清空，无未知请求或重发。夸克没有已核实的内容覆盖参数，未猜测参数发请求；两家仍缺已证明的目标内容版本条件发布合同。

## 夸克未完成会话清理的真实限制

同一自有 4096 字节会话可鉴权列出一片；去掉授权后 GET 返回 403，排除匿名访问。DELETE 使用真实 OSS bucket、无 body／Content-Type，服务端 StringToSign 与本地请求逐字节一致，仍返回 403／SignatureDoesNotMatch。只更改鉴权 meta 的 method 或 bucket 返回同一 Authorization，更改日期才变化；当前 Cookie 鉴权入口不能当作任意 OSS method 的标准签名器。

按[官方安装脚本](https://github.com/quark-clouddrive/quarkclouddrive_offical/blob/main/skills/quarkclouddrive/install.sh) 下载的 1.0.25 公开 ZIP 仅作静态检查，未安装／执行。其 OAuth 上传任务 cancel 使用本地 AbortController；没有查到远端 multipart abort 调用，不能据此声称远端清理已完成。现有 Cookie 与该 OAuth 合同分别保留，不混用授权。

证据 `.build/v3-quark-abort-diagnosis/{report.md,run.jsonl,auth-control.jsonl,anonymous-control.jsonl,source-hashes.json}`。未接入未验证的 abort；原会话仍可列片，归属和唯一 Keychain 上下文保留，`aborted=false`。不涉及用户两条暂停的大文件会话，没有新建云端对象，探针均已退出。

## 百度预创建容量拒绝的当前网页合同

2026-10-25，匿名读取[官方主页面](https://pan.baidu.com/disk/main)实际引入的 [home](https://nd-static.bdstatic.com/m-static/v20-main/home/js/home.0192e673.js) 和 [上传 SDK](https://nd-static.bdstatic.com/m-static/v20-main/home/js/chunk-vendors.ba2fd94a.js)。同一个 SDK 的预创建地址为 `/api/precreate`，回调将非零 errno 直接交给该 SDK 的上传错误映射，其中 -10 明确为空间不足，正数 10 为 superfile 创建失败。现只将该准备阶段的 -10 识别为明确容量拒绝；未知码和 HTTP 错误仍保留未决，不猜测文字。

证据 `.build/baidu-precreate-contract/{report.md,manifest.json,evidence-excerpts.json}` 保存 URL、原始哈希和精确字符／字节偏移。此为当前官方网页接口合同核对，没有填满真实网盘；独立 actor 验证确认 -10 修复原因后可以重试，+10 和未知码不重复预创建。

## 非空秒传与完整内容验证

百度当前网页 SDK 的独立快速上传接口为 `/api/rapidupload`，需要先取得普通预创建 uploadID，再提交固定账号 UK、混淆摘要及公式指定的 256 KiB 真实内容证明。新建 1 MiB 随机样本首次上传完整回读并保留后，同目录新名同内容真实命中秒传，准确新 fsID 的完整 SHA-256 与源一致；同名竞态另存后原对象身份与内容保持。只有 HTTP 成功的业务 errno=404 可继续原会话普通上传；未知响应不能据此重发。原始网页合同、精确偏移及实际日志见 `.build/baidu-precreate-contract/rapid/{report.md,real-seeded/journal.jsonl}`。独立 Native 实证与正式 Core 编排验收分别记录，不把探针等同 App 操作。

夸克真实 1 MiB 随机样本首次发送一片、合并并 finish 后完整回读；保留该样本，以新名上传同内容，哈希协商返回 instantCompleted，分片／OSS 合并／finish 请求均为零。两个准确且不同 FID 完整回读并逐范围比较原字节，SHA-256 一致。两轮共享预算且收尾为零。清理首次响应报错，随后仅只读确认原目录已不存在，没有重发删除。证据 `.build/t08-quark-instant-validation/{report.md,run.jsonl,cleanup-inspect.jsonl,source-hashes.json}`。
