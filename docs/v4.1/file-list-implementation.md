# 原生文件列表实施

- 文件工作区接入 NSOutlineView，名称、修改日期、大小共用原生列模型，清理独立 SwiftUI 表头与列拖动布局。
- 列宽偏好两家共享，原生排序回写 DirectoryBrowserState；日期等宽且精确到秒。
- 保留父子勾选、收起清理、当前层搜索、双击、准确父目录命令与本地文件拖入。
- 适配器采用一次性 Observation 订阅，变化后更新；节点加载任务按节点去重，销毁时取消，委托及回调以弱引用连接。
- 新建定位由原生列表聚焦后消费，分享页继续使用现有 FileTreeRow。
- 2026-10-29：Scripts/build-app.sh 完整构建及签名通过，输出仍为 .build/Ferry Plus.app。原型交互尚待 Computer Use 验收；首次桌面检查为锁屏。
