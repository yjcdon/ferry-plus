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

/// 主窗口顶栏的标题与空白共用拖动入口，控件保留原生事件。
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

    static func dismantleNSView(_ view: TitleView, coordinator: ()) {
        view.stopDragging()
    }

    final class TitleView: NSView {
        private var dragOrigin: (pointer: NSPoint, frame: NSRect, restoreZoom: Bool)?
        private var dragMonitor: Any?
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

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, dragMonitor == nil else { return }
            dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }
                return self.handleTitlebarEvent(event)
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            stopDragging()
            super.viewWillMove(toWindow: newWindow)
        }

        /// 视图离开窗口时释放事件入口；同一个窗口仅保留一份拖动状态。
        func stopDragging() {
            if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
            dragMonitor = nil
            dragOrigin = nil
        }

        /// 只接管从当前主窗口顶栏空白开始的拖动，内容区和控件继续正常派发。
        private func handleTitlebarEvent(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            switch event.type {
            case .leftMouseDown:
                dragOrigin = nil
                guard window.attachedSheet == nil,
                      !window.styleMask.contains(.fullScreen),
                      isTitlebarBackground(event.locationInWindow, in: window) else { return event }
                window.makeKeyAndOrderFront(nil)
                if event.clickCount == 2 {
                    window.performZoom(nil)
                    return nil
                }
                dragOrigin = (screenPoint(for: event, in: window), window.frame, window.isZoomed)
                return nil
            case .leftMouseDragged:
                guard let origin = dragOrigin else { return event }
                let pointer = screenPoint(for: event, in: window)
                if origin.restoreZoom {
                    // 放大窗口实际开始拖动时恢复原尺寸，并让顶栏继续贴住拖动位置。
                    guard hypot(pointer.x - origin.pointer.x, pointer.y - origin.pointer.y) >= 3 else { return nil }
                    window.performZoom(nil)
                    let horizontalAnchor = (origin.pointer.x - origin.frame.minX) / origin.frame.width
                    let topInset = origin.frame.maxY - origin.pointer.y
                    window.setFrameOrigin(NSPoint(x: pointer.x - window.frame.width * horizontalAnchor,
                                                  y: pointer.y + topInset - window.frame.height))
                    dragOrigin = (pointer, window.frame, false)
                } else {
                    window.setFrameOrigin(NSPoint(x: origin.frame.minX + pointer.x - origin.pointer.x,
                                                  y: origin.frame.minY + pointer.y - origin.pointer.y))
                }
                return nil
            case .leftMouseUp:
                guard dragOrigin != nil else { return event }
                dragOrigin = nil
                return nil
            default:
                return event
            }
        }

        /// 根据窗口布局和可见工具栏项目划定空白，随窗口宽度与工具栏收纳同步。
        private func isTitlebarBackground(_ point: NSPoint, in window: NSWindow) -> Bool {
            // 窗口外缘留给系统调整尺寸；顶栏高度使用当前窗口布局。
            let titlebar = NSRect(x: 4, y: window.contentLayoutRect.maxY,
                                  width: window.frame.width - 8,
                                  height: window.frame.height - window.contentLayoutRect.maxY - 4)
            guard titlebar.contains(point) else { return false }
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(type),
                   button.convert(button.bounds, to: nil).contains(point) { return false }
            }
            for item in window.toolbar?.visibleItems ?? [] {
                if item.itemIdentifier == .flexibleSpace || item.itemIdentifier == .space { continue }
                guard let view = item.view, !isDescendant(of: view) else { continue }
                if view.convert(view.bounds, to: nil).contains(point) { return false }
            }
            // 系统工具栏的溢出按钮由 AppKit 创建，也保留其原生交互。
            if let frameView = window.contentView?.superview {
                var hit = frameView.hitTest(frameView.convert(point, from: nil))
                while let view = hit {
                    if view is NSControl, !view.isDescendant(of: self) { return false }
                    hit = view.superview
                }
            }
            return true
        }

        /// 优先使用事件自身的全局位置，避免窗口移动后旧局部坐标再次叠加位移。
        private func screenPoint(for event: NSEvent, in window: NSWindow) -> NSPoint {
            event.cgEvent?.unflippedLocation ?? window.convertPoint(toScreen: event.locationInWindow)
        }
    }
}
