import CoreGraphics
import Foundation

/// Dynamic Island window geometry: pure functions, easy to unit-test.
/// Convention: the panel is fixed at its maximum size, pinned top-centre on the screen;
/// expand/collapse is done by animating the content. All coordinates follow AppKit
/// (origin bottom-left, y up).
public enum IslandGeometry {
    /// Screen info (extracted from NSScreen by the app layer so the pure functions are testable)
    public struct ScreenInfo: Equatable, Sendable {
        public var frame: CGRect
        /// Notch height (NSScreen.safeAreaInsets.top); 0 without a notch
        public var safeAreaTopInset: CGFloat
        /// Physical notch width (derived from auxiliaryTop*Area); nil without a notch
        public var notchWidth: CGFloat?
        /// Menu bar height (frame.maxY - visibleFrame.maxY); used for floating placement on
        /// notchless screens
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
        /// Fixed panel size (covers the largest expanded state + shadow margin)
        public var panelSize: CGSize
        /// Expanded card size
        public var expandedCardSize: CGSize
        /// Compact pill size on notchless screens
        public var compactPillNoNotchSize: CGSize
        /// Width of the "wing" the pill extends on each side of the notch
        public var notchWingWidth: CGFloat
        /// Gap between content and the menu bar on notchless screens
        public var noNotchTopMargin: CGFloat

        /// 1.0× baseline (built-in notched screen). Expanded card width:height ≈ golden ratio
        /// φ (1.618). Panel height has headroom: full task list (~254) + expanded subagent box
        /// (up to ~168) ≈ 422 < 460.
        public static let standard = Layout(
            panelSize: CGSize(width: 440, height: 460),
            expandedCardSize: CGSize(width: 360, height: 222),  // 360/222 ≈ 1.62
            compactPillNoNotchSize: CGSize(width: 232, height: 40),
            notchWingWidth: 92,
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

        /// Scales proportionally by the factor (noNotchTopMargin follows the menu bar and is
        /// not scaled)
        public func scaled(by factor: CGFloat) -> Layout {
            Layout(
                panelSize: CGSize(
                    width: panelSize.width * factor, height: panelSize.height * factor),
                expandedCardSize: CGSize(
                    width: expandedCardSize.width * factor,
                    height: expandedCardSize.height * factor),
                compactPillNoNotchSize: CGSize(
                    width: compactPillNoNotchSize.width * factor,
                    height: compactPillNoNotchSize.height * factor),
                notchWingWidth: notchWingWidth * factor,
                noNotchTopMargin: noNotchTopMargin
            )
        }
    }

    /// UI scale factor from the screen's logical width: a 15″ MacBook Air (1512 wide) is the
    /// 1.0 baseline, larger screens (27″ 4K etc.) scale up proportionally, clamped to
    /// [0.9, 1.6] to guard against extreme sizes.
    public static func scaleFactor(for screen: ScreenInfo) -> CGFloat {
        let referenceWidth: CGFloat = 1512
        let raw = screen.frame.width / referenceWidth
        return min(max(raw, 0.9), 1.6)
    }

    /// Layout for the current screen: baseline × that screen's scale factor.
    public static func layout(for screen: ScreenInfo) -> Layout {
        Layout.standard.scaled(by: scaleFactor(for: screen))
    }

    /// Height of the expanded subagent box nested in the task list (1.0× baseline, not
    /// multiplied by scale). Shows at most 6 rows, plus one "…and N more" row beyond that.
    /// Must match the row height/padding in IslandViews.
    public static func subagentBoxHeight(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let shown = min(count, 6)
        let rows = CGFloat(shown) * 22       // 22 per row
        let gaps = CGFloat(shown - 1) * 4    // 4 between rows
        let overflow: CGFloat = count > 6 ? 16 : 0
        return rows + gaps + overflow + 16   // 16 = box top + bottom padding
    }

    /// 任务列表卡片的行高与间距（1.0× 基准，未乘 scale）。
    /// `TaskListCardView` 按这些值排版，`taskListHeight` 按同一组值算卡片高度 —— 两边共用这一份。
    public enum TaskList {
        public static let maxActiveRows = 4
        public static let maxIdleRows = 3
        public static let topPadding: CGFloat = 10
        /// 标题行：「进行中任务 N」+ 时间模式切换（刘海屏上分居刘海两侧）
        public static let headerHeight: CGFloat = 24
        public static let headerGap: CGFloat = 8
        public static let activeRowHeight: CGFloat = 42
        public static let activeRowSpacing: CGFloat = 6
        /// 子 agent 框与所属行之间的间距
        public static let subagentBoxGap: CGFloat = 4
        /// 进行中超过 maxActiveRows 时的「…等 N 个」
        public static let overflowLineHeight: CGFloat = 16
        /// 进行中与空闲分区之间的分隔线（1pt 线 + 上下各 9）
        public static let dividerHeight: CGFloat = 19
        public static let idleHeaderHeight: CGFloat = 20
        public static let idleRowHeight: CGFloat = 34
        public static let bottomPadding: CGFloat = 10
    }

    /// 展开子 agent 框时不显示空闲分区：两者同时出现会超出 panel 高度（panel 不能加高 ——
    /// 自定义位置存的是 panel 左下角，改高度会让用户拖好的悬浮岛整体上移）
    public static func taskListShowsIdle(idleCount: Int, expandedSubagentCount: Int) -> Bool {
        idleCount > 0 && expandedSubagentCount == 0
    }

    /// 任务列表卡片高度（1.0× 基准，未乘 scale）。
    /// `expandedSubagentCount`：展开的子 agent 框里的子 agent 数（0 = 没有展开）
    public static func taskListHeight(
        activeCount: Int, idleCount: Int, expandedSubagentCount: Int = 0
    ) -> CGFloat {
        typealias M = TaskList
        let activeRows = min(activeCount, M.maxActiveRows)
        let idleRows = min(idleCount, M.maxIdleRows)
        var height = M.topPadding + M.headerHeight + M.headerGap
        if activeRows > 0 {
            height += CGFloat(activeRows) * M.activeRowHeight
                + CGFloat(activeRows - 1) * M.activeRowSpacing
        }
        if activeCount > M.maxActiveRows { height += M.overflowLineHeight }
        if expandedSubagentCount > 0 {
            height += M.subagentBoxGap + subagentBoxHeight(count: expandedSubagentCount)
        }
        if taskListShowsIdle(idleCount: idleCount, expandedSubagentCount: expandedSubagentCount) {
            if activeRows > 0 { height += M.dividerHeight }
            height += M.idleHeaderHeight + CGFloat(idleRows) * M.idleRowHeight
        }
        return height + M.bottomPadding
    }

    /// 自定义位置是否仍然可用：面板顶部的「胶囊带」（顶部 72pt × 中央半宽）须完整落在某块屏内。
    /// 仅擦边相交（如外接屏拔掉/重排后残留的旧坐标）判不可用 → 调用方清存档回默认位。
    /// 纯函数（screens 传 frame 数组），便于单测。
    public static func positionUsable(
        origin: CGPoint, panelSize: CGSize, screens: [CGRect]
    ) -> Bool {
        let bandHeight: CGFloat = 72
        let band = CGRect(
            x: origin.x + panelSize.width * 0.25,
            y: origin.y + panelSize.height - bandHeight,
            width: panelSize.width * 0.5,
            height: bandHeight)
        return screens.contains { $0.contains(band) }
    }

    /// Fixed panel frame: top-centred, top edge flush with the screen's top edge
    public static func panelFrame(screen: ScreenInfo, layout: Layout = .standard) -> CGRect {
        CGRect(
            x: screen.frame.midX - layout.panelSize.width / 2,
            y: screen.frame.maxY - layout.panelSize.height,
            width: layout.panelSize.width,
            height: layout.panelSize.height
        )
    }

    /// Content's top inset within the panel: notched screens start at the very top (blending
    /// with the notch); notchless screens clear the menu bar
    public static func contentTopInset(screen: ScreenInfo, layout: Layout = .standard) -> CGFloat {
        screen.hasNotch ? 0 : screen.menuBarHeight + layout.noNotchTopMargin
    }

    /// Compact pill size: notched screen = notch height + two wings; regular screen = fixed
    /// small pill
    public static func pillSize(screen: ScreenInfo, layout: Layout = .standard) -> CGSize {
        guard screen.hasNotch else { return layout.compactPillNoNotchSize }
        return CGSize(
            width: (screen.notchWidth ?? 196) + layout.notchWingWidth * 2,
            height: screen.safeAreaTopInset
        )
    }

    /// Width in the middle of the pill hidden by the physical notch (content layout must
    /// leave it empty); 0 without a notch
    public static func pillCenterGap(screen: ScreenInfo) -> CGFloat {
        screen.hasNotch ? (screen.notchWidth ?? 196) : 0
    }

    /// Given a content size, computes its actual area in panel coordinates (origin
    /// bottom-left). Used for hitTest pass-through and the hover tracking area.
    public static func interactiveRect(
        contentSize: CGSize, screen: ScreenInfo, layout: Layout = .standard
    ) -> CGRect {
        interactiveRect(
            contentSize: contentSize,
            topInset: contentTopInset(screen: screen, layout: layout),
            layout: layout
        )
    }

    /// Explicit topInset variant (floating mode at a custom position uses topInset = 0)
    public static func interactiveRect(
        contentSize: CGSize, topInset: CGFloat, layout: Layout = .standard
    ) -> CGRect {
        guard contentSize != .zero else { return .zero }
        return CGRect(
            x: (layout.panelSize.width - contentSize.width) / 2,
            y: layout.panelSize.height - topInset - contentSize.height,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    /// Flips a rect between bottom-left and top-left origins (NSHostingView.isFlipped == true,
    /// so hit testing inside the view must use the flipped rect)
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
