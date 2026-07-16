import AppKit
import EurekaKit
import SwiftUI

extension Notification.Name {
    /// 设置页"恢复默认位置"
    static let eurekaResetIslandPosition = Notification.Name("eureka.resetIslandPosition")
}

/// 灵动岛 NSPanel 控制器：panel 固定为最大尺寸，默认贴刘海屏顶部居中；
/// 支持按住拖拽到任意位置（含外接屏），位置持久化，拖回默认位置附近自动吸附回融合形态。
/// 展开/收起全靠 SwiftUI 动画，透明区域 hitTest 穿透。
@MainActor
final class IslandPanelController {
    let viewModel = IslandViewModel()

    private let panel: NSPanel
    private let hostingView: IslandHostingView<IslandRootView>
    private var orderOutWorkItem: DispatchWorkItem?
    private var moveSettleWorkItem: DispatchWorkItem?
    /// 程序化 setFrame 期间忽略 didMove（只响应用户拖拽）
    private var isProgrammaticMove = false
    /// 吸附判定半径（pt）
    private let snapDistance: CGFloat = 40

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // 非激活面板里的控件需要它才能正常响应点击
        panel.becomesKeyOnlyIfNeeded = true
        // 比状态栏高一级：刘海屏上要盖住菜单栏区域才能与刘海融合
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // 阴影由 SwiftUI 画，避免黑色矩形残影
        panel.hidesOnDeactivate = false
        // isMovable 必须为 true，否则 performDrag 被拒绝；
        // 背景拖拽关掉（borderless 无标题栏），移动只能由 hostingView 显式发起
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false

        hostingView = IslandHostingView(rootView: IslandRootView(viewModel: viewModel))
        hostingView.sizingOptions = []  // panel 尺寸固定，不让 SwiftUI 反向驱动窗口
        panel.contentView = hostingView
    }

    /// init 完成后调用：接线回调与系统通知（避免 init 中捕获未完全初始化的 self）
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
        reposition()
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

    /// 用户拖拽产生的移动：去抖后评估吸附与持久化
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
        // 还按着鼠标说明拖拽未结束，继续等
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
            // 吸附回该屏默认位置（刘海屏 → 恢复融合形态）
            IslandPositionStore.clear()
            setFrameProgrammatically(defaultFrame, animate: true)
            viewModel.isFloating = false
        } else {
            viewModel.isFloating = true
            // 跨屏后按新屏比例重设尺寸：锚定左上角（内容顶部）不动
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

    /// 选屏：带刘海的内建屏优先（灵动岛体验最佳），盒盖后回落主屏
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    func reposition() {
        // 有自定义位置且仍在某块屏幕上 → 沿用（浮动样式）
        if let origin = IslandPositionStore.load() {
            // 先按原点定位所在屏（用基准尺寸探测），更新缩放后再用新尺寸成帧
            let probe = NSRect(origin: origin, size: IslandGeometry.Layout.standard.panelSize)
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(probe) }) {
                viewModel.updateScreen(Self.screenInfo(of: screen))
                viewModel.isFloating = true
                setFrameProgrammatically(
                    NSRect(origin: origin, size: viewModel.layout.panelSize), animate: false)
                return
            }
            IslandPositionStore.clear()  // 显示器拔了，回默认
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
        orderOutWorkItem?.cancel()
        orderOutWorkItem = nil
        if display == .hidden {
            // 等收起动画播完再撤窗口
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
            // 不抢焦点地置顶展示
            panel.orderFrontRegardless()
        }
    }
}

/// 自定义位置持久化（UserDefaults，存全局坐标原点）
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
