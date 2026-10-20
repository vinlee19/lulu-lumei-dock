import AppKit
import EurekaKit
import SwiftUI

extension Notification.Name {
    /// Settings "Preview" on a state row. object = `MascotState.rawValue`
    static let eurekaPreviewMascotState = Notification.Name("eureka.previewMascotState")
    /// Settings "Reset to the default position"
    static let eurekaResetMascotPosition = Notification.Name("eureka.resetMascotPosition")
}

/// Companion size picked in Settings; scales the card and the panel together
enum MascotSize: String, CaseIterable {
    case small, medium, large

    var scale: CGFloat {
        switch self {
        case .small: return 0.75
        case .medium: return 1
        case .large: return 1.3
        }
    }

    var title: String {
        switch self {
        case .small: return L10n.text("Small", zhHans: "小")
        case .medium: return L10n.text("Medium", zhHans: "中")
        case .large: return L10n.text("Large", zhHans: "大")
        }
    }

    static func resolve(_ raw: String) -> MascotSize { MascotSize(rawValue: raw) ?? .medium }
}

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
    /// Panel size at medium scale; the bubble needs the headroom above the card
    private static let baseSize = NSSize(width: 180, height: 210)
    private var isProgrammaticMove = false
    private var pointerTimer: Timer?
    private var lastPointerLocation: NSPoint?
    private var currentPackID = MascotPackLoader.builtInID

    init() {
        viewModel = MascotViewModel(pack: MascotPackLoader.builtIn())
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.baseSize),
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(previewRequested(_:)),
            name: .eurekaPreviewMascotState, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(resetPositionRequested),
            name: .eurekaResetMascotPosition, object: nil)
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

    /// Resizes the card and the panel; the right and bottom edges stay put so a companion parked
    /// in a corner does not grow off screen
    func setSize(_ size: MascotSize) {
        viewModel.cardScale = size.scale
        let newSize = NSSize(
            width: Self.baseSize.width * size.scale, height: Self.baseSize.height * size.scale)
        guard panel.frame.size != newSize else { return }
        let old = panel.frame
        setFrame(NSRect(
            origin: NSPoint(x: old.maxX - newSize.width, y: old.minY), size: newSize))
        guard panel.isVisible else { return }
        // Keep a dragged position dragged; an untouched one re-docks to the corner
        if MascotPositionStore.load() != nil {
            MascotPositionStore.save(panel.frame.origin)
        } else {
            reposition()
        }
    }

    @objc private func previewRequested(_ note: Notification) {
        MainActor.assumeIsolated {
            guard panel.isVisible,
                  let raw = note.object as? String, let state = MascotState(rawValue: raw)
            else { return }
            viewModel.preview(state)
        }
    }

    @objc private func resetPositionRequested() {
        MainActor.assumeIsolated {
            MascotPositionStore.clear()
            if panel.isVisible { reposition() }
        }
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
            if movement > 18, viewModel.state == .sleeping, !viewModel.isPreviewing {
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
