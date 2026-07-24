import AppKit
import SwiftUI

/// 桌面吉祥物 NSPanel 控制器:透明浮窗、背景拖拽移动、位置持久化、右键菜单。
/// 显隐由 AppSettings.mascotEnabled 驱动(镜像灵动岛的轻量版)。
@MainActor
final class MascotPanelController {
    let viewModel: MascotViewModel

    /// 右键「隐藏吉祥物」→ 交给 AppDelegate 关掉设置开关(再由观察者隐藏)
    var onRequestHide: () -> Void = {}
    /// 右键「打开设置」
    var onOpenSettings: () -> Void = {}

    private let panel: NSPanel
    private var moveSettle: DispatchWorkItem?
    private var isProgrammaticMove = false
    private var pointerTimer: Timer?
    private var lastPointerLocation: NSPoint?

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
        panel.hasShadow = false  // 阴影由 SwiftUI 画
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true  // 拖卡片即可移动
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
    }

    func start() {
        let root = MascotRootView(
            viewModel: viewModel,
            onHide: { [weak self] in self?.onRequestHide() },
            onOpenSettings: { [weak self] in self?.onOpenSettings() })
        panel.contentView = NSHostingView(rootView: root)
        viewModel.start()
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelMoved),
            name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointerBehavior() }
        }
    }

    func setVisible(_ visible: Bool) {
        if visible {
            reposition()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    func applyPack(id: String) {
        viewModel.setPack(MascotPackLoader.load(packID: id))
    }

    /// 低频采样鼠标位置：idle 时让双角色自然看向鼠标，睡眠时移动可唤醒。
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
        // 000°=上、090°=屏幕右，和 v2 精灵图的顺时针方向契约一致。
        var degrees = atan2(dx, dy) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        viewModel.setLookDirection(Int((degrees / 22.5).rounded()) % 16)
    }

    // MARK: - 位置

    private func reposition() {
        if let origin = MascotPositionStore.load() {
            let frame = NSRect(origin: origin, size: panel.frame.size)
            if NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
                setFrame(frame)
                return
            }
            MascotPositionStore.clear()
        }
        // 默认:主屏右下角
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

/// 吉祥物自定义位置持久化(独立于灵动岛)
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
