# 4.1 同名上传与旧版本回读

日期：2026-10-29。关联 C25、C26、C32、C33、C48。所有操作均通过实际 App 与 Computer Use 完成，目标为两家独立的 `FerryPlus-V41-20261029-CUA` 样本目录。

## 执行结果

| 网盘与策略 | 实际结果 |
| --- | --- |
| 百度：跳过 | 同名任务进入已跳过，原文件保留 |
| 百度：保留两份 | 原 `small.txt` 保持原修改时间，新增 `small (1).txt`，上传完成 |
| 百度：覆盖并保留旧版本 | 上传内容不同的 4800 字节 `small.txt`，任务完成；明细显示内容一致及旧版本入口 |
| 百度：定位旧版本 | 明细定位菜单打开对应云端目录并勾选 snapshot 备份；下载确认准确列出四个选中对象 |
| 夸克：跳过 | 同名任务进入已跳过，当前列表活动任务归零 |
| 夸克：保留两份 | 原文件与 `small (1).txt` 同时存在；副本下载至独立目录后与源文件一致 |

## 独立内容比对

原始样本 3400 字节，SHA-256：`f1a54c3f4bc4f96d6aa952c82f4905b490859e14b846d607f2c914ade040f91a`。

替换样本 4800 字节，SHA-256：`e81660f1e45004800e3e7ae9b5503a597f9b001038819a8b28a5b822c6ef03f5`。

百度通过 App 回读四个文件到 `.build/v41-evidence/downloads/baidu-conflicts`：当前 `small.txt` 与替换样本逐字节一致；`small (1).txt`、snapshot 备份及 claim 文件与原始样本逐字节一致。报告为 `.build/v41-evidence/baidu-conflicts-roundtrip.json`。

夸克通过 App 回读 `small (1).txt` 到 `.build/v41-evidence/downloads/quark-conflicts`，3400 字节及 SHA-256 与原始样本一致。报告为 `.build/v41-evidence/quark-conflicts-roundtrip.json`。

原始目录的零字节、小文件、分片文件回环另见[Core 审查记录](core-final-review.md)。本轮补证覆盖同名策略和旧版本恢复入口，样本清理归入 C50 收尾。
