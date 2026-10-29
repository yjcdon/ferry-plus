# 4.1 Debug 演示隔离

日期：2026-10-29。关联 T14、C40—C46。

## 问题与范围

原演示仅切换任务和百度账号，QuarkAccountSession 初始化仍从正式钥匙串恢复账号，导致演示菜单混入真实夸克名称。代理密码及设置写入同样沿用正式入口。

## 实现

- `KeychainItem` 在 Debug 且 `FerryDemo=YES` 时使用进程内凭据字典。百度、夸克、代理密码及上传恢复授权共用这一边界，演示启动为空，读写及删除均在内存中完成。
- `AppPreferences` 在同一演示条件下路由到独立 `io.github.yjcdon.FerryPlus.Demo` 偏好域。业务设置、设置分类、浏览位置、网盘偏好和列宽都使用该入口；详情场景键加演示前缀。
- 演示参数继续从启动参数域读取；演示业务设置保持现有默认初始化方式，任务仍由既有 DemoData 样本和临时任务空间承载。
- 两家登录窗口在演示中说明【演示模式】，真实官方页面留给正常账号模式；演示退出和代理编辑沿用内存凭据及独立偏好域。
- 正式默认模式及 Debug 的 `-FerryDemo NO -FerryDemoAppearance dark/light` 继续使用正式偏好和钥匙串。Release 编译剔除演示分支。

## 检查与验收

已检查所有 App 内显式 UserDefaults 读写、AppStorage、详情 SceneStorage 和 KeychainItem 调用方，生产凭据服务 API 保持原样。

- SDK 26.5、Swift 6、macOS 14 目标下，Debug 与 Release 条件的全部 App 静态类型检查通过。
- 现有账号与代理设置测试筛选通过：15 个测试、4 个套件，使用已构建测试产物执行。
- 全部相关文件差异检查通过；DirectoryBrowserState 的偏好路由替换在主代理路径恢复提交后进行，保留其已提交逻辑。
- 实际演示启动账号组成、设置修改隔离和退出后真实账号恢复由主代理统一构建后验收。
