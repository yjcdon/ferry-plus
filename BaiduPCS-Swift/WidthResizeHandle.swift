import AppKit
import SwiftUI

/// 原生鼠标事件以窗口坐标计算位移，列边界移动时拖动起点保持不变。
struct WidthResizeHandle: NSViewRepresentable {
    @Binding var width: CGFloat
    var adjacentWidth: Binding<CGFloat>? = nil
    let minimum: CGFloat
    let maximum: CGFloat
    var fillsHeight = false

    func makeNSView(context: Context) -> ResizeView {
        ResizeView(width: $width, adjacentWidth: adjacentWidth, minimum: minimum, maximum: maximum, fillsHeight: fillsHeight)
    }

    func updateNSView(_ view: ResizeView, context: Context) {
        view.width = $width
        view.adjacentWidth = adjacentWidth
        view.minimum = minimum
        view.maximum = maximum
        view.fillsHeight = fillsHeight
    }

    final class ResizeView: NSView {
        var width: Binding<CGFloat>
        var adjacentWidth: Binding<CGFloat>?
        var minimum: CGFloat
        var maximum: CGFloat
        var fillsHeight: Bool
        private var initialX: CGFloat = 0
        private var initialWidth: CGFloat = 0
        private var initialAdjacentWidth: CGFloat = 0

        init(width: Binding<CGFloat>, adjacentWidth: Binding<CGFloat>?, minimum: CGFloat, maximum: CGFloat, fillsHeight: Bool) {
            self.width = width
            self.adjacentWidth = adjacentWidth
            self.minimum = minimum
            self.maximum = maximum
            self.fillsHeight = fillsHeight
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
            let height = fillsHeight ? bounds.height : 14
            NSRect(x: (bounds.width - 1) / 2, y: (bounds.height - height) / 2, width: 1, height: height).fill()
        }
        override func mouseDown(with event: NSEvent) {
            initialX = event.locationInWindow.x
            initialWidth = width.wrappedValue
            initialAdjacentWidth = adjacentWidth?.wrappedValue ?? 0
        }
        override func mouseDragged(with event: NSEvent) {
            var delta = event.locationInWindow.x - initialX
            delta = min(initialWidth - minimum, max(initialWidth - maximum, delta))
            if let adjacentWidth {
                delta = min(600 - initialAdjacentWidth, max(48 - initialAdjacentWidth, delta))
                adjacentWidth.wrappedValue = initialAdjacentWidth + delta
            }
            width.wrappedValue = initialWidth - delta
        }
    }
}
