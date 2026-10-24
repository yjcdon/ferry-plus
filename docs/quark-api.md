# 夸克接口实现与验证

QuarkKit 使用官方网页登录后保存在本应用钥匙串中的会话。文件、分享、转存及下载接口共用登录客户端，不建立第二套凭据存储。

## 已实现接口

| 能力 | 接口 | 行为 |
| --- | --- | --- |
| 账号目录 | drive-pc.quark.cn `/1/clouddrive/file/sort` | 完整分页；失败不返回部分列表；检查重复 fid 和返回的父目录身份 |
| 分享访问 | pan.quark.cn `/1/clouddrive/share/sharepage/token`、`detail` | 提取码及分享错误分类；文件令牌仅驻留当前会话 |
| 创建目录 | drive-pc.quark.cn `/1/clouddrive/file` | 返回服务器 fid；同名冲突不伪造新目录身份 |
| 提交转存 | drive-pc.quark.cn `/1/clouddrive/share/sharepage/save` | 立即返回 task_id，供调度器持久化 |
| 任务核对 | drive-pc.quark.cn `/1/clouddrive/task` | 独立查询，有界、可取消等待；取消本地等待不代表服务端撤销 |
| 下载地址 | drive.quark.cn `/1/clouddrive/file/download` | HTTPS 地址及所需请求头，Cookie 按域和路径选择 |
| 清理 | drive.quark.cn `/1/clouddrive/file/delete` | 仅接受明确 fid，禁止根目录；返回异步回执时等待确认后再成功返回 |

公共适配器负责将 fid 转换为远端引用；公共任务不保存 Cookie、stoken、文件分享令牌或下载直链。转存任务重启后可用已保存 task_id 查询，无须保存分享会话令牌。

## 当前证据和边界

- 官方登录、凭据保存、独立进程恢复、账号与根目录鉴权已实际通过。
- 2026-10-24：正式适配器与任务／下载引擎链路完成夸克 148851 字节小文件下载，根目录返回 2 项；验证进程退出码为 0，输出本地 SHA-256。样例没有改写或清理网盘源文件。
- QuarkKit、FerryCore 构建通过；临时边界冒烟覆盖分享文案和提取码解析、外域拒绝、非法目录、根目录删除及轮询参数边界。
- 完整分享转存、分页、大文件续传、直链刷新和真实清理仍需复用登录状态执行。接口代码存在、构建通过不表示这些真实接口已验收。
- Mac 已解锁，两家账号已在新 App 菜单确认恢复。本机构建切换固定证书后等待首次钥匙串迁移授权，之后继续 T-21 及 Computer Use 回归；固定签名跨重建授权尚未验证。

上游协议依据见 [架构设计第 8 节](architecture.md#8-夸克接口依据与待验证内容)。最终完成状态以 [任务清单](tasks.md) 和真实验证记录为准。
