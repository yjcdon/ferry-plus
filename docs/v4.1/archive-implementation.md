# 4.1 历史下载依据归档实施记录

日期：2026-10-29。对应 T09 的历史依据内部归档部分、C30—C31。

## 实现

- `JobCoordinator.remove` 默认 `.preserve` 在任务停止、引擎完成位置确认后生成最终历史依据。
- `DownloadIntegrityArchive` 将清单保存到任务存储同级 `IntegrityManifests/<任务 UUID>.json`，使用现有 IntegrityManifest 格式；原子写入后读回核对条目。
- 磁盘归档在独立任务中执行，协调器等待完成后再次核对当前依据，再进入既有精确对象记录归档与任务移除流程。
- 保存失败保留任务与原件，恢复存储后可重试；重试覆盖同一任务归档。已导出清单和显式放弃的旧调用保持兼容。
- 历史清单只含路径、大小、算法和摘要；精确对象已验证记录继续由原 integrityStore 规则生成。

## 调用方迁移

主窗口可清理历史清单选择／导出流程，直接调用现有 `AppModel.remove(... integrityDisposition: .preserve)`，也可省略该参数使用默认值。Core 在移除流程内部取得最终依据，面板提前准备清单的分支可一并清理。

## 验证

`bash Scripts/test-packages.sh --filter 'JobCoordinatorTests/removalAuto|JobCoordinatorTests/removalArchive'` 通过：2 个测试、4 个参数场景。

- pending／mismatch／verified 历史依据自动归档，任务成功移除，本地文件保留，历史依据保持参考语义。
- 归档目录写入失败时任务和原件保留，恢复目录后同一任务重试成功。

`bash Scripts/test-packages.sh --filter 'JobCoordinatorTests/remove'` 通过原有 3 个移除回归测试，覆盖原件保留、用户同名文件保留及取消期间刚完成文件的实际路径。

真实 App 的历史入口清理与交互验收由主窗口迁移后执行。

## C30—C31 补充验证

在既有 JobCoordinatorTests 中补充三个测试，使用现有存储、真实本地摘要校正 API 和 RemovalGateSource 门控，测试采用明确事件条件同步。

- 百度、夸克精确对象的 verified 下载移除后，原账号、远端引用、版本、摘要及验证时间进入 IntegrityStore；原件保留，原版本可查询，其他版本查询为空。
- 取得旧清单后通过 verifyCompletedFile 修正用户摘要；使用旧清单移除时保留当前任务和原件，改用自动归档重试后保存最新依据并完成移除。
- 引擎到达明确取消收尾门控后取消移除，释放门控，确认暂停任务和原件仍在；再次移除成功，历史依据保留。

`/tmp/ferry-v41-archive-final-tests.log` 记录本轮 3 个测试、4 个参数场景通过。原子磁盘写入与读回之间的变化交错仍为待验证；同步归档方法当前没有可注入挂起点。本轮仅补充测试和文档。

随后合并运行归档与原有移除回归，8 个测试通过，日志 `/tmp/ferry-v41-removal-regression-final.log`。
