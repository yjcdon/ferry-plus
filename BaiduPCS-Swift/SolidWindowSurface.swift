import AppKit
import SwiftUI

extension View {
    /// 应用窗口使用实色内容与工具栏表面，保留系统标题栏、焦点和窗口操作。
    func solidWindowSurface() -> some View {
        background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
            .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            .background(SolidWindowConfigurator().frame(width: 0, height: 0))
    }

    /// 业务确认面板与其系统承载表面采用相同实色，浅深外观跟随系统。
    func solidSheetSurface() -> some View {
        background(Color(nsColor: .windowBackgroundColor))
            .presentationBackground(Color(nsColor: .windowBackgroundColor))
    }
}

extension ToolbarContent {
    /// 新系统隐藏工具栏项目共享材质，分组和系统收纳行为继续由工具栏负责。
    @ToolbarContentBuilder
    func solidToolbarBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// 在视图实际连接窗口时配置公开窗口属性；无需监听器或重复调度任务。
private struct SolidWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> SurfaceView { SurfaceView() }

    func updateNSView(_ view: SurfaceView, context: Context) { view.configureWindow() }

    final class SurfaceView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        /// 只更新发生变化的窗口属性，避免外观刷新引发重复布局。
        func configureWindow() {
            guard let window else { return }
            if !window.isOpaque { window.isOpaque = true }
            if window.backgroundColor != .windowBackgroundColor { window.backgroundColor = .windowBackgroundColor }
            if window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = false }
            if window.titlebarSeparatorStyle != .line { window.titlebarSeparatorStyle = .line }
        }
    }
}
