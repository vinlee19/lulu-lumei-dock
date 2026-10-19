import AppKit
import EurekaKit
import SwiftUI

extension Notification.Name {
    /// Settings' "Restore default position"
    static let eurekaResetIslandPosition = Notification.Name("eureka.resetIslandPosition")
}

/// A borderless window defaults to `canBecomeKey == false`, so the question card's "Other…" field
/// gets no keyboard input. Allowing it doesn't steal focus: with `becomesKeyOnlyIfNeeded`, only
/// clicking a control like a text field makes it key, clicking buttons still leaves focus alone;
/// nonactivatingPanel also ensures becoming key doesn't activate this app
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Dynamic Island NSPanel controller: the panel is fixed at max size, by default pinned top-center
/// under the notch; can be dragged to any position (including external displays), position is
/// persisted, and dragging back near the default snaps back to the fused form. Expand/collapse is
/// all SwiftUI animation; transparent areas pass hitTest through.
@MainActor
final class IslandPanelController {
    let viewModel = IslandViewModel()

    private let panel: IslandPanel
    private let hostingView: IslandHostingView<IslandRootView>
    /// The app the user was in before we took the keyboard for "Other" input (handed back once
    /// typing is done)
    private var keyboardOwnerBeforeTyping: NSRunningApplication?
    private var orderOutWorkItem: DispatchWorkItem?
    private var moveSettleWorkItem: DispatchWorkItem?
    /// Ignore didMove during programmatic setFrame (only respond to user drags)
    private var isProgrammaticMove = false
    /// Snap radius (pt)
    private let snapDistance: CGFloat = 40
    /// Outside-island click monitors while the task list is expanded (global + local), removed on
    /// collapse
    private var outsideClickMonitors: [Any] = []

    init() {
        panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Controls in a non-activating panel need this to respond to clicks properly
        panel.becomesKeyOnlyIfNeeded = true
        // One level above the status bar: on notched screens it must cover the menu bar area to
        // merge with the notch
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // SwiftUI draws the shadow; avoids a black rectangular ghost
        panel.hidesOnDeactivate = false
        // isMovable must be true or performDrag is refused; background dragging is off (borderless,
        // no title bar); moves can only be started explicitly by hostingView
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false

        hostingView = IslandHostingView(rootView: IslandRootView(viewModel: viewModel))
        hostingView.sizingOptions = []  // Panel size is fixed; don't let SwiftUI drive the window size back
        panel.contentView = hostingView
    }

    /// Call after init: wire callbacks and system notifications (avoids capturing a partially
    /// initialized self in init)
    func start() {
        hostingView.interactiveRectProvider = { [weak viewModel] in
            viewModel?.interactiveRect ?? .zero
        }
        hostingView.onHoverChange = { [weak viewModel] hovering in
            viewModel?.setHovering(hovering)
        }
        viewModel.onDisplayChange = { [weak self] display in
            self?.displayChanged(display)
        }
        viewModel.onKeyboardChange = { [weak self] wantsKeyboard in
            self?.keyboardChanged(wantsKeyboard)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove),
            name: NSWindow.didMoveNotification,
            object: panel
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resetPositionRequested),
            name: .eurekaResetIslandPosition,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: .eurekaLanguageDidChange,
            object: nil
        )
        reposition()
    }

    @objc private func languageDidChange() {
        MainActor.assumeIsolated {
            viewModel.noteLanguage(L10n.current)
        }
    }

    @objc private func screensChanged() {
        MainActor.assumeIsolated { reposition() }
    }

    @objc private func resetPositionRequested() {
        MainActor.assumeIsolated {
            IslandPositionStore.clear()
            reposition()
        }
    }

    /// Move caused by a user drag: debounce, then evaluate snapping and persistence
    @objc private func panelDidMove() {
        MainActor.assumeIsolated {
            guard !isProgrammaticMove else { return }
            moveSettleWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.moveSettled() }
            }
            moveSettleWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    private func moveSettled() {
        // Mouse still down means the drag hasn't ended; keep waiting
        guard NSEvent.pressedMouseButtons == 0 else {
            panelDidMove()
            return
        }
        guard let screen = panel.screen ?? targetScreen() else { return }
        let info = Self.screenInfo(of: screen)
        viewModel.updateScreen(info)

        let defaultFrame = IslandGeometry.panelFrame(screen: info, layout: viewModel.layout)
        let origin = panel.frame.origin
        let dx = abs(origin.x - defaultFrame.origin.x)
        let dy = abs(origin.y - defaultFrame.origin.y)

        if dx < snapDistance && dy < snapDistance {
            // Snap back to this screen's default position (notched screen → restore the merged
            // form)
            IslandPositionStore.clear()
            setFrameProgrammatically(defaultFrame, animate: true)
            viewModel.isFloating = false
        } else {
            viewModel.isFloating = true
            // After crossing screens, resize to the new screen's scale: keep the top-left corner
            // (content top) anchored
            let newSize = viewModel.layout.panelSize
            if newSize != panel.frame.size {
                let anchored = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - newSize.height)
                setFrameProgrammatically(NSRect(origin: anchored, size: newSize), animate: true)
                IslandPositionStore.save(anchored)
            } else {
                IslandPositionStore.save(origin)
            }
        }
    }

    /// Screen choice: notched built-in screen first (best Dynamic Island experience), falling back
    /// to the main screen when the lid is closed
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    func reposition() {
        // Custom position exists and is still sufficiently visible → reuse it (floating style)
        if let origin = IslandPositionStore.load() {
            // Strict visibility check (the capsule band must be fully on screen): leftover
            // coordinates that merely graze the screen (external screen unplugged/rearranged) would
            // put the island almost entirely off screen → treat as unusable, clear the saved
            // position and go back to default
            let probeSize = IslandGeometry.Layout.standard.panelSize
            let usable = IslandGeometry.positionUsable(
                origin: origin, panelSize: probeSize,
                screens: NSScreen.screens.map(\.frame))
            let probe = NSRect(origin: origin, size: probeSize)
            if usable, let screen = NSScreen.screens.first(where: { $0.frame.intersects(probe) }) {
                viewModel.updateScreen(Self.screenInfo(of: screen))
                viewModel.isFloating = true
                setFrameProgrammatically(
                    NSRect(origin: origin, size: viewModel.layout.panelSize), animate: false)
                return
            }
            IslandPositionStore.clear()  // Display unplugged / position no longer visible: back to default
        }
        guard let screen = targetScreen() else { return }
        let info = Self.screenInfo(of: screen)
        viewModel.updateScreen(info)
        viewModel.isFloating = false
        setFrameProgrammatically(
            IslandGeometry.panelFrame(screen: info, layout: viewModel.layout),
            animate: false
        )
    }

    private func setFrameProgrammatically(_ frame: NSRect, animate: Bool) {
        isProgrammaticMove = true
        panel.setFrame(frame, display: true, animate: animate)
        isProgrammaticMove = false
    }

    static func screenInfo(of screen: NSScreen) -> IslandGeometry.ScreenInfo {
        var notchWidth: CGFloat?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
        }
        return IslandGeometry.ScreenInfo(
            frame: screen.frame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            notchWidth: notchWidth,
            menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY
        )
    }

    private func displayChanged(_ display: IslandViewModel.Display) {
        if display == .taskList {
            installOutsideClickMonitors()
        } else {
            removeOutsideClickMonitors()
        }
        orderOutWorkItem?.cancel()
        orderOutWorkItem = nil
        if display == .hidden {
            // Wait for the collapse animation to finish before removing the window
            let work = DispatchWorkItem {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.viewModel.display == .hidden else { return }
                    self.panel.orderOut(nil)
                }
            }
            orderOutWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        } else if !panel.isVisible {
            reposition()
            // Bring to front without stealing focus
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Question card input

    /// When the question card opens its "Other…" field, make the panel key (without activating this
    /// app); hand the keyboard back to the previous app when done
    private func keyboardChanged(_ wantsKeyboard: Bool) {
        if wantsKeyboard {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                keyboardOwnerBeforeTyping = front
            }
            panel.makeKeyAndOrderFront(nil)
        } else {
            guard panel.isKeyWindow else { return }
            keyboardOwnerBeforeTyping?.activate()
            keyboardOwnerBeforeTyping = nil
        }
    }

    // MARK: - Collapse on outside click

    /// The panel is nonactivating and passes hitTest through outside the island, so it almost never
    /// becomes key window; resignKey / didResignActive never arrive → "losing focus" can only be
    /// detected by monitoring mouse-downs outside the island. The global monitor catches clicks
    /// landing in other apps (mouse events need no Accessibility permission); the local monitor
    /// catches clicks in this app's windows (status bar popover, main window, the island itself).
    private func installOutsideClickMonitors() {
        guard outsideClickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseDown() }
        }) {
            outsideClickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseDown() }
            return event  // observe only, never intercept; the click is delivered as usual
        }) {
            outsideClickMonitors.append(local)
        }
    }

    private func removeOutsideClickMonitors() {
        outsideClickMonitors.forEach(NSEvent.removeMonitor)
        outsideClickMonitors.removeAll()
    }

    /// Clicks within the island's visible area go to SwiftUI tap / drag handling; outside it,
    /// collapse the task list
    private func handleMouseDown() {
        // interactiveRect is in panel coordinates (origin bottom-left); translate to global screen
        // coordinates before comparing
        let islandRect = viewModel.interactiveRect.offsetBy(
            dx: panel.frame.minX, dy: panel.frame.minY)
        guard !islandRect.contains(NSEvent.mouseLocation) else { return }
        viewModel.dismissTaskList()
    }
}

/// Custom position persistence (UserDefaults, stores the global-coordinate origin)
enum IslandPositionStore {
    private static let xKey = "islandCustomOriginX"
    private static let yKey = "islandCustomOriginY"
    private static let flagKey = "islandHasCustomPosition"

    static func save(_ origin: NSPoint) {
        let defaults = UserDefaults.standard
        defaults.set(Double(origin.x), forKey: xKey)
        defaults.set(Double(origin.y), forKey: yKey)
        defaults.set(true, forKey: flagKey)
    }

    static func load() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: flagKey) else { return nil }
        return NSPoint(
            x: defaults.double(forKey: xKey),
            y: defaults.double(forKey: yKey))
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: flagKey)
    }
}
