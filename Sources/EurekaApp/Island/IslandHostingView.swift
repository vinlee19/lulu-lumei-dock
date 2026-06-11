import AppKit
import EurekaKit
import SwiftUI

/// 承载灵动岛 SwiftUI 内容的 NSHostingView：
/// - 透明区域点击穿透（panel 固定为最大尺寸，岛外区域不能挡鼠标）
/// - 不激活 app 也响应首次点击
/// - 用 NSTrackingArea 自管 hover（onHover 在 nonactivating panel 上不可靠）
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    /// 当前可交互区域（panel 坐标系，原点左下），由控制器注入
    var interactiveRectProvider: @MainActor () -> NSRect = { .zero }
    var onHoverChange: @MainActor (Bool) -> Void = { _ in }

    private var trackingArea: NSTrackingArea?
    private var mouseDownLocation: NSPoint?
    private var didDrag = false

    /// 注入的矩形是原点左下；NSHostingView 是 flipped（原点左上），
    /// 视图内判断必须翻转，否则命中区落到 panel 底部空白区（点击全部穿透）
    private var interactiveRectInView: NSRect {
        let rect = interactiveRectProvider()
        return isFlipped
            ? IslandGeometry.flippedRect(rect, containerHeight: bounds.height)
            : rect
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 点不在岛的可视范围内 → 穿透给下层窗口
        guard interactiveRectInView.contains(convert(point, from: superview)) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - 拖拽检测（点按交给 SwiftUI：岛内按钮与背景 tap 自然共存）

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        didDrag = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        defer { super.mouseDragged(with: event) }
        guard let start = mouseDownLocation, !didDrag else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        if dx * dx + dy * dy > 16 {
            didDrag = true
            // 交给窗口服务器拖动整个 panel（位置持久化在控制器的 didMove 观察里）。
            // performDrag 会吞掉后续 mouseUp/mouseExited——必须手动复位 hover，
            // 否则自动收起被永久暂停，岛停在旧内容上（曾导致整夜不更新）。
            // 它同时吞掉 mouseUp → SwiftUI 的 tap 手势不会在拖拽后误触发。
            if insideInteractive {
                insideInteractive = false
                onHoverChange(false)
            }
            window?.performDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        didDrag = false
        super.mouseUp(with: event)
    }

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
        let inside = interactiveRectInView.contains(point)
        if inside != insideInteractive {
            insideInteractive = inside
            onHoverChange(inside)
        }
    }
}
