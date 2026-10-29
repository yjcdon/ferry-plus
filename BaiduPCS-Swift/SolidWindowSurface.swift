import AppKit
import SwiftUI

extension View {
    /// 自绘标题保留同一份导航标题，系统工具栏负责其余命令和收纳。
    @ViewBuilder
    func customWindowTitle() -> some View {
        if #available(macOS 15.0, *) { toolbar(removing: .title) }
        else { self }
    }
    /// 工具栏操作组使用统一实色衬底，保持搜索与按钮分组清晰。
    func toolbarControlSurface() -> some View {
        labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color(nsColor: .controlColor), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 3)
    }

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
            if !window.isMovable { window.isMovable = true }
            if !window.isMovableByWindowBackground { window.isMovableByWindowBackground = true }
            if !window.isOpaque { window.isOpaque = true }
            if window.backgroundColor != .windowBackgroundColor { window.backgroundColor = .windowBackgroundColor }
            if window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = false }
            if window.titlebarSeparatorStyle != .line { window.titlebarSeparatorStyle = .line }
        }
    }
}

/// 标题区域按屏幕坐标跟随鼠标移动窗口；按钮与搜索继续使用各自事件。
struct WindowTitleDragView: NSViewRepresentable {
    let title: String
    let subtitle: String?

    func makeNSView(context: Context) -> TitleView { TitleView() }

    func updateNSView(_ view: TitleView, context: Context) {
        let subtitleText = subtitle ?? ""
        if view.titleField.stringValue != title { view.titleField.stringValue = title }
        if view.subtitleField.stringValue != subtitleText { view.subtitleField.stringValue = subtitleText }
        view.subtitleField.isHidden = subtitle == nil
    }

    final class TitleView: NSView {
        private var dragOrigin: (pointer: NSPoint, window: NSPoint)?
        let titleField = NSTextField(labelWithString: "")
        let subtitleField = NSTextField(labelWithString: "")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            titleField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            subtitleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            subtitleField.textColor = .secondaryLabelColor
            titleField.lineBreakMode = .byTruncatingMiddle
            subtitleField.lineBreakMode = .byTruncatingTail
            let stack = NSStackView(views: [titleField, subtitleField])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 0
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
        /// 保存按下时的屏幕位置，使窗口移动后事件坐标仍保持同一基准。
        override func mouseDown(with event: NSEvent) {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            if event.clickCount > 1 {
                dragOrigin = nil
                super.mouseDown(with: event)
            } else {
                dragOrigin = (screenPoint(for: event, in: window), window.frame.origin)
            }
        }

        /// 直接使用 AppKit 窗口坐标更新位置，随鼠标拖动逐次执行。
        override func mouseDragged(with event: NSEvent) {
            guard let window, let origin = dragOrigin else { return }
            let pointer = screenPoint(for: event, in: window)
            window.setFrameOrigin(NSPoint(x: origin.window.x + pointer.x - origin.pointer.x,
                                          y: origin.window.y + pointer.y - origin.pointer.y))
        }

        override func mouseUp(with event: NSEvent) { dragOrigin = nil }

        /// 优先使用事件自身的全局位置，避免窗口移动后旧局部坐标再次叠加位移。
        private func screenPoint(for event: NSEvent, in window: NSWindow) -> NSPoint {
            event.cgEvent?.unflippedLocation ?? window.convertPoint(toScreen: event.locationInWindow)
        }
    }
}
