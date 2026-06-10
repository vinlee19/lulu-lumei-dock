import CoreGraphics
import Foundation

/// 灵动岛窗口几何：纯函数，便于单测。
/// 约定：panel 固定为最大尺寸贴屏幕顶部居中，展开/收起靠内容动画；
/// 所有坐标遵循 AppKit（原点左下，y 向上）。
public enum IslandGeometry {
    /// 屏幕信息（由 app 层从 NSScreen 提取，便于纯函数测试）
    public struct ScreenInfo: Equatable, Sendable {
        public var frame: CGRect
        /// 刘海高度（NSScreen.safeAreaInsets.top），无刘海为 0
        public var safeAreaTopInset: CGFloat
        /// 物理刘海宽度（由 auxiliaryTop*Area 推得），无刘海为 nil
        public var notchWidth: CGFloat?
        /// 菜单栏高度（frame.maxY - visibleFrame.maxY），无刘海屏悬浮定位用
        public var menuBarHeight: CGFloat

        public var hasNotch: Bool { safeAreaTopInset > 1 }

        public init(
            frame: CGRect,
            safeAreaTopInset: CGFloat = 0,
            notchWidth: CGFloat? = nil,
            menuBarHeight: CGFloat = 24
        ) {
            self.frame = frame
            self.safeAreaTopInset = safeAreaTopInset
            self.notchWidth = notchWidth
            self.menuBarHeight = menuBarHeight
        }
    }

    public struct Layout: Equatable, Sendable {
        /// panel 固定尺寸（覆盖最大展开态 + 阴影余量）
        public var panelSize: CGSize
        /// 展开卡片尺寸
        public var expandedCardSize: CGSize
        /// 无刘海屏的 compact 胶囊尺寸
        public var compactPillNoNotchSize: CGSize
        /// 刘海屏胶囊向两侧各延伸的"翼"宽
        public var notchWingWidth: CGFloat
        /// 无刘海屏内容与菜单栏的间距
        public var noNotchTopMargin: CGFloat

        public static let standard = Layout(
            panelSize: CGSize(width: 460, height: 190),
            expandedCardSize: CGSize(width: 384, height: 124),
            compactPillNoNotchSize: CGSize(width: 184, height: 30),
            notchWingWidth: 66,
            noNotchTopMargin: 5
        )

        public init(
            panelSize: CGSize,
            expandedCardSize: CGSize,
            compactPillNoNotchSize: CGSize,
            notchWingWidth: CGFloat,
            noNotchTopMargin: CGFloat
        ) {
            self.panelSize = panelSize
            self.expandedCardSize = expandedCardSize
            self.compactPillNoNotchSize = compactPillNoNotchSize
            self.notchWingWidth = notchWingWidth
            self.noNotchTopMargin = noNotchTopMargin
        }
    }

    /// panel 的固定 frame：顶部居中、上沿与屏幕上沿齐平
    public static func panelFrame(screen: ScreenInfo, layout: Layout = .standard) -> CGRect {
        CGRect(
            x: screen.frame.midX - layout.panelSize.width / 2,
            y: screen.frame.maxY - layout.panelSize.height,
            width: layout.panelSize.width,
            height: layout.panelSize.height
        )
    }

    /// 内容距 panel 顶部的留白：刘海屏从顶端开始（与刘海融合），无刘海避开菜单栏
    public static func contentTopInset(screen: ScreenInfo, layout: Layout = .standard) -> CGFloat {
        screen.hasNotch ? 0 : screen.menuBarHeight + layout.noNotchTopMargin
    }

    /// compact 胶囊尺寸：刘海屏 = 刘海高度 + 两翼；普通屏 = 固定小胶囊
    public static func pillSize(screen: ScreenInfo, layout: Layout = .standard) -> CGSize {
        guard screen.hasNotch else { return layout.compactPillNoNotchSize }
        return CGSize(
            width: (screen.notchWidth ?? 196) + layout.notchWingWidth * 2,
            height: screen.safeAreaTopInset
        )
    }

    /// 胶囊中部被物理刘海遮挡的宽度（内容布局需留空），无刘海为 0
    public static func pillCenterGap(screen: ScreenInfo) -> CGFloat {
        screen.hasNotch ? (screen.notchWidth ?? 196) : 0
    }

    /// 给定内容尺寸，算出其在 panel 坐标系（原点左下）中的实际区域。
    /// hitTest 穿透与 hover 跟踪区域用。
    public static func interactiveRect(
        contentSize: CGSize, screen: ScreenInfo, layout: Layout = .standard
    ) -> CGRect {
        guard contentSize != .zero else { return .zero }
        let topInset = contentTopInset(screen: screen, layout: layout)
        return CGRect(
            x: (layout.panelSize.width - contentSize.width) / 2,
            y: layout.panelSize.height - topInset - contentSize.height,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    /// 原点左下 ↔ 原点左上 的矩形翻转（NSHostingView.isFlipped == true，
    /// 视图内命中判断必须用翻转后的矩形）
    public static func flippedRect(_ rect: CGRect, containerHeight: CGFloat) -> CGRect {
        guard rect != .zero else { return .zero }
        return CGRect(
            x: rect.minX,
            y: containerHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
