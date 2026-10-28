# 网盘品牌图标出处

获取日期：2026-10-28。两张图标来自对应网盘官网 HTML 的 `rel=icon` 链接，用于侧边栏区分百度、夸克来源。未用 AI 生成或重绘品牌图形；图标归相应品牌所有。

| 资源 | 官网及原始资源 | 仓库文件 | 尺寸／文件大小 | 处理 |
| --- | --- | --- | --- | --- |
| 百度网盘 | [百度网盘官网](https://pan.baidu.com/) 引用的 [favicon.ico](https://nd-static.bdstatic.com/m-static/wp-brand/favicon.ico) | `BaiduPCS-Swift/Resources/BaiduNetdisk.png` | 32 × 32，1662 字节 | 用 macOS sips 将官网 ICO 转为 PNG，保留原尺寸与颜色 |
| 夸克网盘 | [夸克网盘官网](https://pan.quark.cn/) 引用的 [官网 PNG 图标](https://image.quark.cn/s/uae/g/3o/broccoli/resource/202602/f6439020-13b4-11f1-9342-3944993de2f6.png) | `BaiduPCS-Swift/Resources/QuarkNetdisk.png` | 64 × 64，3340 字节 | 用 sips 输出 64px PNG，保留原图形与颜色 |

## 展示与打包

- `ProviderIcon` 通过 Bundle 中实际 PNG 文件读取 NSImage 并缓存，以 20pt 等比、original 原色显示，不依赖未编译的 Asset Catalog。图片本身带透明／浅色底，明暗背景的实际显示由 App 验收确认。
- 本机 `Scripts/build-app.sh` 在 codesign 之前将两张 PNG 复制到 `Ferry Plus.app/Contents/Resources`。缺失资源时复制失败即终止构建，不用字母图标静默替代。
- Xcode 项目以 `PBXFileSystemSynchronizedRootGroup` 同步整个 `BaiduPCS-Swift` 目录，并将该组关联应用 target；Resources 内 PNG 不在排除名单中，由资源阶段同步打包，不需要逐文件修改工程。
- 静态文件与尺寸已核对，并目视确认原始图标。最新构建 App 已实际显示两张原色图标；PNG 与打包资源摘要一致，严格签名验证通过。当前完成浅色界面目视核对，不将深色界面写成已实测。

## 文件摘要

```text
BaiduNetdisk.png  SHA-256 27dcd63767da8fdf519e8545c21610fde78f5b09e5fc1f0ca5a142e4cd784337
QuarkNetdisk.png  SHA-256 f3e63167bc5a16d56641d1ae4c94dee6adab0fd1eded046f7cf754c46be5e9e2
```
