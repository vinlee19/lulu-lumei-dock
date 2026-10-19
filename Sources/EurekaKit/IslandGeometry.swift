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

    /// Row heights and spacing of the task list card (1.0× baseline, not multiplied by scale).
    /// `TaskListCardView` lays out with these values and `taskListHeight` computes the card height
    /// from the same set -- both sides share this one copy.
    public enum TaskList {
        public static let maxActiveRows = 4
        public static let maxIdleRows = 3
        public static let topPadding: CGFloat = 10
        /// Title row: "Running tasks N" + time-mode toggle (split across both sides of the notch on
        /// notched screens)
        public static let headerHeight: CGFloat = 24
        public static let headerGap: CGFloat = 8
        public static let activeRowHeight: CGFloat = 42
        public static let activeRowSpacing: CGFloat = 6
        /// Spacing between a subagent box and its row
        public static let subagentBoxGap: CGFloat = 4
        /// The "…N total" row when running tasks exceed maxActiveRows
        public static let overflowLineHeight: CGFloat = 16
        /// Divider between the running and idle sections (1pt line + 9 above and below)
        public static let dividerHeight: CGFloat = 19
        public static let idleHeaderHeight: CGFloat = 20
        public static let idleRowHeight: CGFloat = 34
        public static let bottomPadding: CGFloat = 10
    }

    /// Row heights and spacing of the question card (1.0× baseline, not multiplied by scale).
    /// `QuestionCardView` lays out with these values, and `questionCardHeight` computes the height
    /// from the same set.
    public enum QuestionCard {
        /// When fused with the notch, content starts at the notch's bottom edge (`topInset` is the
        /// notch height passed by the caller); otherwise this is the top margin
        public static let plainTopPadding: CGFloat = 14
        /// Source + header label + progress "1/2"
        public static let headerHeight: CGFloat = 20
        /// Height of each line of question text; laid out by the actual line count (1–2), so a
        /// one-line question leaves no second-line gap
        public static let questionLineHeight: CGFloat = 20
        public static let maxQuestionLines = 2
        public static let sectionGap: CGFloat = 8
        public static let optionHeight: CGFloat = 38
        public static let optionSpacing: CGFloat = 6
        /// The "Other…" row (same height once expanded into a text field)
        public static let otherRowHeight: CGFloat = 32
        /// The "Answer in terminal" / "Confirm" button row
        public static let footerHeight: CGFloat = 28
        public static let bottomPadding: CGFloat = 12
        /// No matter how many options, only this many rows are laid out (AskUserQuestion specifies
        /// 2–4)
        public static let maxOptions = 4
    }

    /// Question area height (1.0× baseline): line count clamped to 1–2
    public static func questionTextHeight(lines: Int) -> CGFloat {
        CGFloat(min(max(lines, 1), QuestionCard.maxQuestionLines)) * QuestionCard.questionLineHeight
    }

    /// Question card height (1.0× baseline). `questionLines`: number of lines the question text
    /// lays out to; `topInset`: the notch height when fused with the notch, otherwise 0
    public static func questionCardHeight(
        optionCount: Int, questionLines: Int, topInset: CGFloat
    ) -> CGFloat {
        typealias M = QuestionCard
        let rows = min(max(optionCount, 1), M.maxOptions)
        let top = max(topInset + 6, M.plainTopPadding)
        return top + M.headerHeight + M.sectionGap + questionTextHeight(lines: questionLines)
            + M.sectionGap
            + CGFloat(rows) * M.optionHeight + CGFloat(rows - 1) * M.optionSpacing
            + M.optionSpacing + M.otherRowHeight + M.sectionGap + M.footerHeight
            + M.bottomPadding
    }

    /// The idle section is hidden while a subagent box is expanded: showing both would exceed the
    /// panel height (the panel can't grow -- a custom position stores the panel's bottom-left
    /// corner, so changing the height would shift the user's placed floating island upward)
    public static func taskListShowsIdle(idleCount: Int, expandedSubagentCount: Int) -> Bool {
        idleCount > 0 && expandedSubagentCount == 0
    }

    /// Task list card height (1.0× baseline, not multiplied by scale). `expandedSubagentCount`:
    /// number of subagents in the expanded subagent box (0 = none expanded)
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

    /// Whether a custom position is still usable: the "pill band" at the top of the panel (top 72pt
    /// × central half-width) must lie entirely within one screen. A mere edge intersection (e.g.
    /// stale coordinates left after unplugging / rearranging an external display) counts as
    /// unusable → the caller clears the saved value and returns to the default position. Pure
    /// function (screens are passed as an array of frames), easy to unit test.
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
