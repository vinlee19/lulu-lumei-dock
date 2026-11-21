import AppKit

/// Tells a click from a drag on the floating panels (Dynamic Island, desktop companion).
///
/// Both panels host SwiftUI content with tap gestures, so `isMovableByWindowBackground` can't be
/// used: SwiftUI takes the mouseDown, and the window never starts moving. Instead the hosting view
/// feeds its mouse events here and, once a press travels past `threshold`, hands the drag to the
/// window server with `NSWindow.performDrag(with:)`.
///
/// `performDrag` runs until the button is released and swallows that mouseUp (and any
/// mouseExited). That is why a drag never ends in a SwiftUI tap, and also why the island has to
/// reset its hover state itself before calling it.
struct PanelDragTracker {
    /// Travel in points before a press becomes a drag; below it, a slightly shaky click stays a
    /// click
    static let threshold: CGFloat = 4

    private var start: NSPoint?
    private var dragging = false

    mutating func mouseDown(_ event: NSEvent) {
        start = event.locationInWindow
        dragging = false
    }

    /// True exactly once per press: the moment it first crosses `threshold`
    mutating func shouldBeginDrag(_ event: NSEvent) -> Bool {
        guard let start, !dragging else { return false }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        guard dx * dx + dy * dy > Self.threshold * Self.threshold else { return false }
        dragging = true
        return true
    }

    mutating func mouseUp() {
        start = nil
        dragging = false
    }
}
