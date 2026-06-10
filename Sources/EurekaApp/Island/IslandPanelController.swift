import AppKit
import EurekaKit
import SwiftUI

/// 灵动岛 NSPanel 控制器：panel 固定为最大尺寸贴屏幕顶部，
/// 展开/收起全靠 SwiftUI 动画（绕开 NSWindow frame 动画与 SwiftUI 不同步的坑），
/// 透明区域 hitTest 穿透。
@MainActor
final class IslandPanelController {
    let viewModel = IslandViewModel()

    private let panel: NSPanel
    private let hostingView: IslandHostingView<IslandRootView>
    private var orderOutWorkItem: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // 比状态栏高一级：刘海屏上要盖住菜单栏区域才能与刘海融合
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // 阴影由 SwiftUI 画，避免黑色矩形残影
        panel.hidesOnDeactivate = false
        panel.isMovable = false
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
        reposition()
    }

    @objc private func screensChanged() {
        MainActor.assumeIsolated {
            reposition()
        }
    }

    /// 选屏：带刘海的内建屏优先（灵动岛体验最佳），盒盖后回落主屏
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    func reposition() {
        guard let screen = targetScreen() else { return }
        let info = Self.screenInfo(of: screen)
        viewModel.updateScreen(info)
        panel.setFrame(
            IslandGeometry.panelFrame(screen: info, layout: viewModel.layout),
            display: true
        )
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
