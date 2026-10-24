# 本地文件上传可行性验证

验证日期：2026-10-24。基线版本：Ferry Plus 2.0；本次只验证协议和现有会话，不增加上传界面或修改已发布 App。

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
| 百度 | 20971643 字节 | 6 片，每片 MD5 核对通过 | 通过，远端大小一致 | 首个 CDN 地址返回 HTTP 403；另一次回读超时，备用地址等待超过 4 分钟后终止，完整回读未通过 |
| 夸克 | 4096 字节 | 1 片 | 通过 | SHA-256 一致 |
| 夸克 | 20971643 字节 | 6 片 | 通过 | SHA-256 一致 |

**结论：两家现有网页登录状态都可以用于本地文件上传，不必为这条路径新增 OAuth 授权。** 百度分片文件已经上传并合并；后续完整下载验证遇到的 403 属于回读环节，不能据此宣称上传失败，也不能把远端大小相同等同于完整回读校验通过。

首轮夸克分片文件 SHA-256：`ae84172edabc892da433f114667d231f4349311e0e61948e645619245ae7c2ee`。所有轮次的专用测试目录均已移入网盘回收站并确认从原位置消失，没有永久清空回收站。定位过程中增加过一轮双网盘复测和一轮仅百度分片复测；夸克复测两种样本仍通过完整回读。百度专用复测清楚记录了 `merged`、`remote_size_verified`，随后首个 CDN 回读返回 403，备用地址等待超过 4 分钟后主动终止；之后由清理程序先核对目录身份和内容范围，再完成本轮目录清理。

本机脱敏证据：

- `.build/upload-probe/progress.jsonl`：首轮两家的上传、回读及清理结果。
- `.build/upload-probe/baidu-multipart-followup.jsonl`：定位复测，含百度下载请求超时、两家清理，以及夸克分片回读成功。
- `.build/upload-probe/baidu-instrumented.jsonl`：百度专用复测，确认 6 片 MD5、合并、远端大小和回读 403 所在阶段。
- `.build/upload-probe/final-cleanup.jsonl`：主动终止备用地址等待后，核对专用目录名称、文件名称及大小，再删除并确认原目录消失。

因此按“上传后完整下载并核对 SHA-256”的严格标准，4 种组合有 3 种通过；百度分片文件只确认到上传合并与远端大小，不能报告四项全部通过。

## 后续实现边界

现有账号、代理、目录浏览、账号归属和部分任务界面可以复用。正式上传仍需新增上传引擎及任务持久化，处理暂停恢复、本地文件变化、同名冲突、空间不足、会话失效及部分成功；本次探针不证明这些产品行为已实现。

正式实现继续使用 Swift 原生请求，不引入 Node 或 Go 运行时。按分片读取文件并限制并发；本次探针为有界样本使用内存数据，不作为正式大文件内存策略。
