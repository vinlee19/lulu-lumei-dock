import AppKit
import SwiftUI

// MARK: - Themed pop-up
//
// SwiftUI's `.popover` is an NSPopover: the system draws its frame, arrow, corner radius and
// translucent material, and picks up the colors of whatever sits behind it. No theme token
// reaches that frame, so under Neo-Brutalism or a palette theme the pop-up still looks like
// stock macOS. `themedPopup` draws the whole thing itself in a borderless child panel: surface
// fill, card border, theme radius, and the brutal hard shadow on the shape only.
//
// Use it for list-style pop-ups (pickers, filters, action lists). The panel never becomes key,
// so it cannot host text input; keep `.popover` for anything with a text field.

enum PopupAlignment {
    /// Pop-up's left edge on the trigger's left edge (pull-downs on the left of a bar).
    case leading
    /// Pop-up's right edge on the trigger's right edge (overflow buttons on the right).
    case trailing
}

extension View {
    /// Shows `content` in a themed pop-up below this view while `isPresented` is true.
    /// A click outside, Esc, or the window losing focus sets it back to false.
    func themedPopup<PopupContent: View>(
        isPresented: Binding<Bool>, alignment: PopupAlignment = .leading,
        @ViewBuilder content: @escaping () -> PopupContent
    ) -> some View {
        background(ThemedPopupAnchor(isPresented: isPresented, alignment: alignment, content: content))
    }
}

/// The pop-up's frame: everything a theme says about a floating container.
struct ThemedPopupSurface<Content: View>: View {
    @ViewBuilder var content: Content

    /// Room left inside the panel for the brutal offset shadow (4/4); soft styles use the
    /// window's own shadow instead.
    static var shadowInset: CGFloat { ThemeStyle.current.isHardEdged ? 5 : 0 }

    var body: some View {
        let radius = Theme.radius.container
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .fixedSize()
            .background(shape.fill(Theme.surface))
            .overlay(shape.strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
            .clipShape(shape)
            // Hard shadow on a separate shape layer, never on the text-bearing content.
            .background(shape.fill(Theme.surface).themeCardShadow())
            .padding(.trailing, Self.shadowInset)
            .padding(.bottom, Self.shadowInset)
    }
}

private struct ThemedPopupAnchor<PopupContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let alignment: PopupAlignment
    let content: () -> PopupContent

    func makeCoordinator() -> ThemedPopupController { ThemedPopupController() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let controller = context.coordinator
        let binding = $isPresented
        controller.onDismiss = { binding.wrappedValue = false }
        controller.alignment = alignment
        guard isPresented else {
            controller.close()
            return
        }
        let root = AnyView(ThemedPopupSurface { content() })
        if controller.isShowing {
            controller.update(root)
        } else {
            // The anchor may not be in a window yet on the first pass.
            DispatchQueue.main.async { controller.show(root, anchor: view) }
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: ThemedPopupController) {
        coordinator.close()
    }
}

/// A borderless panel that never takes focus: clicks reach its buttons directly while the
/// main window keeps its key status (and its active look).
private final class ThemedPopupPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on a non-key panel press the button under it.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class ThemedPopupController {
    var onDismiss: (() -> Void)?
    var alignment: PopupAlignment = .leading

    private var panel: ThemedPopupPanel?
    private var hosting: FirstMouseHostingView?
    private weak var anchor: NSView?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    var isShowing: Bool { panel != nil }

    func show(_ root: AnyView, anchor: NSView) {
        guard panel == nil, let parent = anchor.window else { return }
        self.anchor = anchor
        let hosting = FirstMouseHostingView(rootView: root)
        let panel = ThemedPopupPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = !ThemeStyle.current.isHardEdged
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.appearance = parent.effectiveAppearance
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        place()
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        panel.invalidateShadow()
        installDismissal(parent: parent)
    }

    func update(_ root: AnyView) {
        hosting?.rootView = root
        place()
        panel?.invalidateShadow()
    }

    func close() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        hosting = nil
    }

    private func dismiss() {
        close()
        onDismiss?()
    }

    /// Below the trigger with a 4pt gap; above it when the screen runs out; kept on screen.
    private func place() {
        guard let panel, let hosting, let anchor, let window = anchor.window else { return }
        let size = hosting.fittingSize
        let trigger = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var x = alignment == .leading
            ? trigger.minX
            : trigger.maxX - size.width + ThemedPopupSurface<EmptyView>.shadowInset
        x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        var y = trigger.minY - 4 - size.height
        if y < visible.minY + 4 { y = trigger.maxY + 4 }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func installDismissal(parent: NSWindow) {
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown {
                // Esc closes the pop-up and is swallowed so it doesn't also close a sheet.
                if event.keyCode == 53 {
                    self.dismiss()
                    return nil
                }
                return event
            }
            if event.window === panel { return event }
            // A click on the trigger itself is left to the trigger, which toggles the pop-up
            // closed; dismissing here too would reopen it on mouse-up.
            if let anchor = self.anchor, event.window === anchor.window,
               anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
                return event
            }
            self.dismiss()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
    }
}
