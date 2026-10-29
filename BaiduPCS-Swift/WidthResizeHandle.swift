import AppKit
import SwiftUI

/// 详情分隔线以窗口坐标计算位移，边界移动时拖动起点保持不变。
struct WidthResizeHandle: NSViewRepresentable {
    @Binding var width: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat

    func makeNSView(context: Context) -> ResizeView {
        ResizeView(width: $width, minimum: minimum, maximum: maximum)
    }

    func updateNSView(_ view: ResizeView, context: Context) {
        view.width = $width
        view.minimum = minimum
        view.maximum = maximum
    }

    final class ResizeView: NSView {
        var width: Binding<CGFloat>
        var minimum: CGFloat
        var maximum: CGFloat
        private var initialX: CGFloat = 0
        private var initialWidth: CGFloat = 0

        init(width: Binding<CGFloat>, minimum: CGFloat, maximum: CGFloat) {
            self.width = width
            self.minimum = minimum
            self.maximum = maximum
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
            NSRect(x: (bounds.width - 1) / 2, y: 0, width: 1, height: bounds.height).fill()
        }
        override func mouseDown(with event: NSEvent) {
            initialX = event.locationInWindow.x
            initialWidth = width.wrappedValue
        }
        override func mouseDragged(with event: NSEvent) {
            var delta = event.locationInWindow.x - initialX
            delta = min(initialWidth - minimum, max(initialWidth - maximum, delta))
            width.wrappedValue = initialWidth - delta
        }
    }
}
