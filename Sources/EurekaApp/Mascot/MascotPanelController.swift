import AppKit
import SwiftUI

/// Desktop mascot NSPanel controller: transparent floating window, background drag to move,
/// position persistence, context menu. Visibility is driven by AppSettings.mascotEnabled (a
/// lightweight mirror of the Dynamic Island).
@MainActor
final class MascotPanelController {
    let viewModel: MascotViewModel
    let animationRuntime = MascotAnimationRuntime()

    /// Context menu "Hide mascot" → hands off to AppDelegate to turn off the setting (the observer
    /// then hides it)
    var onRequestHide: () -> Void = {}
    /// Context menu "Open Settings"
    var onOpenSettings: () -> Void = {}

    private let panel: NSPanel
    private var moveSettle: DispatchWorkItem?
    private var isProgrammaticMove = false
    private var pointerTimer: Timer?
    private var lastPointerLocation: NSPoint?
    private var currentPackID = MascotPackLoader.builtInID

    init() {
        viewModel = MascotViewModel(pack: MascotPackLoader.builtIn())
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 210),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // SwiftUI draws the shadow
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true  // Drag the card to move it
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
    }

    func start() {
        let root = MascotRootView(
            viewModel: viewModel,
            animationRuntime: animationRuntime,
            onHide: { [weak self] in self?.onRequestHide() },
            onOpenSettings: { [weak self] in self?.onOpenSettings() })
        panel.contentView = NSHostingView(rootView: root)
        animationRuntime.start()
        viewModel.start()
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelMoved),
            name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(packFilesChanged(_:)),
            name: .eurekaMascotPackChanged, object: nil)
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointerBehavior() }
        }
    }

    func setVisible(_ visible: Bool) {
        animationRuntime.setVisible(visible)
        if visible {
            reposition()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    func applyPack(id: String) {
        currentPackID = id
        viewModel.setPack(MascotPackLoader.load(packID: id))
    }

    /// Reloads right after the Settings page swaps an image / renames the current mascot (the pack
    /// id doesn't change, so the setting won't trigger it)
    @objc private func packFilesChanged(_ note: Notification) {
        MainActor.assumeIsolated {
            guard (note.object as? String) == currentPackID else { return }
            applyPack(id: currentPackID)
        }
    }

    /// Samples the mouse position at low frequency: in idle the two characters naturally look
    /// toward the mouse; while asleep, moving it can wake them.
    private func updatePointerBehavior() {
        guard panel.isVisible else {
            lastPointerLocation = nil
            viewModel.setLookDirection(nil)
            return
        }
        let pointer = NSEvent.mouseLocation
        if let previous = lastPointerLocation {
            let movement = hypot(pointer.x - previous.x, pointer.y - previous.y)
            if movement > 18, viewModel.state == .sleeping {
                viewModel.wake()
            }
        }
        lastPointerLocation = pointer

        guard viewModel.state == .idle else {
            viewModel.setLookDirection(nil)
            return
        }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let dx = pointer.x - center.x
        let dy = pointer.y - center.y
        let distance = hypot(dx, dy)
        guard distance >= 70 else {
            viewModel.setLookDirection(nil)
            return
        }
        // 000° = up, 090° = screen right, matching the v2 sprite sheet's clockwise direction
        // contract.
        var degrees = atan2(dx, dy) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        viewModel.setLookDirection(Int((degrees / 22.5).rounded()) % 16)
    }

    // MARK: - Position

    private func reposition() {
        if let origin = MascotPositionStore.load() {
            let frame = NSRect(origin: origin, size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
                setFrame(frame)
                return
            }
            MascotPositionStore.clear()
        }
        // Default: bottom-right corner of the main screen
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24)
        setFrame(NSRect(origin: origin, size: size))
    }

    private func setFrame(_ frame: NSRect) {
        isProgrammaticMove = true
        panel.setFrame(frame, display: true)
        isProgrammaticMove = false
    }

    @objc private func panelMoved() {
        MainActor.assumeIsolated {
            guard !isProgrammaticMove else { return }
            let origin = panel.frame.origin
            moveSettle?.cancel()
            let work = DispatchWorkItem { MascotPositionStore.save(origin) }
            moveSettle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    @objc private func screensChanged() {
        MainActor.assumeIsolated {
            if panel.isVisible { reposition() }
        }
    }
}

/// Mascot custom position persistence (independent of the Dynamic Island)
enum MascotPositionStore {
    private static let xKey = "mascotOriginX"
    private static let yKey = "mascotOriginY"
    private static let flagKey = "mascotHasPosition"

    static func save(_ origin: NSPoint) {
        let defaults = UserDefaults.standard
        defaults.set(Double(origin.x), forKey: xKey)
        defaults.set(Double(origin.y), forKey: yKey)
        defaults.set(true, forKey: flagKey)
    }

    static func load() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: flagKey) else { return nil }
        return NSPoint(x: defaults.double(forKey: xKey), y: defaults.double(forKey: yKey))
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: flagKey)
    }
}
