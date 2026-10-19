import AppKit
import EurekaKit
import SwiftUI

/// NSHostingView hosting the Dynamic Island SwiftUI content:
/// - clicks pass through transparent areas (the panel is fixed at max size; areas outside the
///   island must not block the mouse)
/// - responds to the first click without activating the app
/// - manages hover itself via NSTrackingArea (onHover is unreliable on a nonactivating panel)
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    /// Current interactive region (panel coordinates, origin bottom-left), injected by the
    /// controller
    var interactiveRectProvider: @MainActor () -> NSRect = { .zero }
    var onHoverChange: @MainActor (Bool) -> Void = { _ in }

    private var trackingArea: NSTrackingArea?
    private var mouseDownLocation: NSPoint?
    private var didDrag = false

    /// The injected rect has a bottom-left origin; NSHostingView is flipped (top-left origin), so
    /// in-view checks must flip it, or the hit area lands in the empty bottom of the panel (every
    /// click passes through)
    private var interactiveRectInView: NSRect {
        let rect = interactiveRectProvider()
        return isFlipped
            ? IslandGeometry.flippedRect(rect, containerHeight: bounds.height)
            : rect
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Point is outside the island's visible area → pass through to the window below
        guard interactiveRectInView.contains(convert(point, from: superview)) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Drag detection (taps go to SwiftUI: in-island buttons and background taps coexist naturally)

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
            // Hand off to the window server to drag the whole panel (position persistence is in the
            // controller's didMove observer). performDrag swallows the following
            // mouseUp/mouseExited -- hover must be reset manually, or auto-dismiss stays paused
            // forever and the island sticks on stale content (once caused a whole night without
            // updates). It also swallows mouseUp → SwiftUI's tap gesture won't misfire after a
            // drag.
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
