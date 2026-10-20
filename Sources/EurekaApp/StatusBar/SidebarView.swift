import EurekaKit
import SwiftUI

/// Main window's left navigation bar (macOS System Settings style: search entry + grouped items +
/// brand-colored selected capsule + bottom brand area).
///
/// Extracted from `PopoverRootView` into its own view for two reasons:
///  1. The offscreen renderer can snapshot it alone (`--render-shell`), so size/spacing changes no
///     longer need eyeballing on a real machine;
///  2. `PopoverRootView` has 14 injected dependencies, while the sidebar only needs "current
///     selection + rate-limit badge + version".
///
/// The brand appears only once, at the **bottom**. The top used to repeat the wordmark; it is now
/// the visible entry to ⌘K global search, which otherwise had no on-screen affordance at all.
struct SidebarView: View {
    let selected: PopoverRootView.Tab
    /// Rate-limit badge (nil when there's no data)
    let limitsBadge: (text: String, color: Color)?
    /// History count badge (nil at 0; wired the same way as the rate-limit badge)
    var historyBadge: String? = nil
    let appVersion: String
    let onSelect: (PopoverRootView.Tab) -> Void
    /// Click on the bottom brand area (jumps to "Settings → About"); renderers may omit it
    var onOpenAbout: (() -> Void)?
    /// Click on the top search field (opens the ⌘K palette); renderers may omit it
    var onOpenSearch: (() -> Void)?

    /// Fixed sidebar width. Usable row width = 165 − 8×2 (outer) − 8×2 (inside the button) = 133pt,
    /// the hard upper bound for enlarging any icon/label.
    static let width: CGFloat = 165

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // No divider under the field: its own outline already separates it from the groups,
            // and the 9pt a divider costs keeps the column within the 512pt minimum height
            searchField
                .padding(.bottom, 2)
            // The item area must scroll. `MainWindowController` uses `hosting.sizingOptions = []`
            // -- overflowing content is **clipped** rather than growing the window, and
            // `window.minSize` 540 is the frame height including the title bar (the content area is
            // only ~512). Measured: 12 items + 5 group labels + brand footer leave only a dozen or
            // so pt of slack at 512; one more group or a larger system font size would clip the
            // footer. Wrapped in a ScrollView nothing can be clipped no matter how many groups;
            // with slack the content naturally hugs the top.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(PopoverRootView.Tab.sidebarGroups.enumerated()), id: \.offset) {
                        _, group in
                        // Group label (small grey emphasis, replacing a plain divider) Spacing is
                        // derived from the minimum window height: **12** items + 5 group labels
                        // should all be visible within ~512pt of content height where possible (if
                        // not, nothing clips -- the outer ScrollView is the fallback). Adding the
                        // Instructions tab tightened this and SidebarNavButton's row height by 1pt
                        // each: before that, at 512 the whole "System / Settings" group fell
                        // outside the scroll area, hiding the Settings entry by default.
                        Text(group.label)
                            .font(Theme.font.themed(9.5, .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 2)
                        ForEach(group.tabs, id: \.self) { tab in
                            SidebarNavButton(
                                title: tab.title, icon: tab.icon, tileColor: tab.tileColor,
                                badge: tab == .limits ? limitsBadge?.text
                                    : (tab == .history ? historyBadge : nil),
                                badgeColor: (tab == .limits ? limitsBadge?.color : nil)
                                    ?? .secondary,
                                isSelected: selected == tab
                            ) {
                                onSelect(tab)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            brandFooter
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .frame(width: Self.width)
        .background(Theme.surfaceSecondary)
    }

    /// Search field look-alike: a button, not a text field. Typing happens in the palette itself,
    /// so this only has to say "search lives here, ⌘K opens it".
    private var searchField: some View {
        Button {
            onOpenSearch?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(Theme.font.themed(10.5, .medium))
                Text(L10n.text("Search", zhHans: "搜索"))
                    .font(Theme.font.themed(11.5))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("⌘K")
                    .font(Theme.font.themedMono(9.5, .medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Theme.hairline, lineWidth: 1))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            // 4 + no divider below keeps the field within the old wordmark + divider height, so the
            // System group still fits at the 512pt minimum
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.sidebar)
                    .fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.sidebar)
                    .strokeBorder(
                        Theme.controlOutline?.color ?? Theme.hairline,
                        lineWidth: Theme.controlOutline?.width ?? 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius.sidebar))
        }
        .buttonStyle(.plain)
        .help(L10n.text("Search everywhere (⌘K)", zhHans: "全局搜索（⌘K）"))
    }

    /// Bottom-left brand area: enlarged logo + name + version, the whole block clickable → Settings
    /// → About
    private var brandFooter: some View {
        Button {
            onOpenAbout?()
        } label: {
            HStack(spacing: 8) {
                LuluLogoTile(size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("lulu-lumei-dock")
                        .font(Theme.font.themed(10, .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("v\(appVersion)")
                        .font(Theme.font.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius.sidebar))
        }
        .buttonStyle(.plain)
        .help(L10n.text("About lulu-lumei-dock", zhHans: "关于 lulu-lumei-dock"))
        .padding(.bottom, 4)
    }
}
