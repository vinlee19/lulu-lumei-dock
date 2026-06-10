import AppKit
import SwiftUI

/// 承载灵动岛 SwiftUI 内容的 NSHostingView：
/// - 透明区域点击穿透（panel 固定为最大尺寸，岛外区域不能挡鼠标）
/// - 不激活 app 也响应首次点击
/// - 用 NSTrackingArea 自管 hover（onHover 在 nonactivating panel 上不可靠）
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    /// 当前可交互区域（panel/view 坐标系，原点左下），由控制器注入
    var interactiveRectProvider: @MainActor () -> NSRect = { .zero }
    var onHoverChange: @MainActor (Bool) -> Void = { _ in }

    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 点不在岛的可视范围内 → 穿透给下层窗口
        guard interactiveRectProvider().contains(convert(point, from: superview)) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private var insideInteractive = false

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if insideInteractive {
            insideInteractive = false
            onHoverChange(false)
        }
    }

    private func updateHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inside = interactiveRectProvider().contains(point)
        if inside != insideInteractive {
            insideInteractive = inside
            onHoverChange(inside)
        }
    }
}
