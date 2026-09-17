import AppKit

/// 细滚动条：轨道透明，滑块为圆角细条，鼠标悬停时加粗。
/// 滚动条滑块不受界面圆角 token 约束（与浏览器滚动条滑块同理）。
final class ThinScroller: NSScroller {
    private var isHovering = false {
        didSet { if isHovering != oldValue { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        Layout.scrollerTrack
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // 轨道不绘制。
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.width > 0, knob.height > 0 else { return }

        let thickness = isHovering ? Layout.scrollerKnobHover : Layout.scrollerKnob
        let inset = Layout.scrollerInset
        let isVertical = bounds.height >= bounds.width
        let rect: NSRect = if isVertical {
            NSRect(x: bounds.maxX - thickness - inset, y: knob.minY + inset, width: thickness, height: max(thickness, knob.height - inset * 2))
        } else {
            NSRect(x: knob.minX + inset, y: bounds.maxY - thickness - inset, width: max(thickness, knob.width - inset * 2), height: thickness)
        }

        (isHovering ? Palette.scrollerKnobHover : Palette.scrollerKnob).setFill()
        NSBezierPath(roundedRect: rect, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }
}

/// 始终使用覆盖式滚动条：不占用正文宽度，滚动停止后自动淡出。
/// 系统设置为“始终显示滚动条”时 AppKit 会切回传统样式，这里固定为覆盖式。
final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    func installThinScrollers() {
        verticalScroller = ThinScroller()
        horizontalScroller = ThinScroller()
        super.scrollerStyle = .overlay
    }
}
