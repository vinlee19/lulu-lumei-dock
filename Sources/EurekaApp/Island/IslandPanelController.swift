import AppKit
import EurekaKit
import SwiftUI

extension Notification.Name {
    /// Settings' "Restore default position"
    static let eurekaResetIslandPosition = Notification.Name("eureka.resetIslandPosition")
}

/// Dynamic Island NSPanel controller: the panel is fixed at max size, by default top-centered
/// against the notched screen; supports press-and-drag to any position (including external
/// screens), persists the position, and snaps back to the merged form when dragged near the
/// default. Expand/collapse is all SwiftUI animation; transparent areas pass hitTest through.
@MainActor
final class IslandPanelController {
    let viewModel = IslandViewModel()

    private let panel: NSPanel
    private let hostingView: IslandHostingView<IslandRootView>
    private var orderOutWorkItem: DispatchWorkItem?
    private var moveSettleWorkItem: DispatchWorkItem?
    /// Ignore didMove during programmatic setFrame (only respond to user drags)
    private var isProgrammaticMove = false
    /// Snap radius (pt)
    private let snapDistance: CGFloat = 40
    /// 任务列表展开期间的岛外点击监听（global + local），收起即移除
    private var outsideClickMonitors: [Any] = []

    init() {
        panel = NSPanel(
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

    // MARK: - 岛外点击收起

    /// panel 是 nonactivating 且岛外 hitTest 穿透，几乎不会成为 key window，
    /// resignKey / didResignActive 都等不到 → 「失焦」只能靠监听岛外的鼠标按下。
    /// global 监听落到其他 app 的点击（鼠标事件不需要辅助功能权限），
    /// local 监听落到本 app 窗口（状态栏 popover、主窗口、岛自身）的点击。
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
            return event  // 只观察不拦截，点击照常送达
        }) {
            outsideClickMonitors.append(local)
        }
    }

    private func removeOutsideClickMonitors() {
        outsideClickMonitors.forEach(NSEvent.removeMonitor)
        outsideClickMonitors.removeAll()
    }

    /// 点在岛的可视范围内交给 SwiftUI tap / 拖拽处理；范围外收起任务列表
    private func handleMouseDown() {
        // interactiveRect 是 panel 坐标（原点左下），平移到全局屏幕坐标再比
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
