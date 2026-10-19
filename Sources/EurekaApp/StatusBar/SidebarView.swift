import EurekaKit
import SwiftUI

/// Main window's left navigation bar (macOS System Settings style: brand header + grouped items +
/// brand-colored selected capsule + bottom brand area).
///
/// Extracted from `PopoverRootView` into its own view for two reasons:
///  1. The offscreen renderer can snapshot it alone (`--render-shell`), so size/spacing changes no
///     longer need eyeballing on a real machine;
///  2. `PopoverRootView` has 14 injected dependencies, while the sidebar only needs "current
///     selection + rate-limit badge + version".
///
/// The brand mark appears only once, at the **bottom**. Previously there was an 18pt one at the top and a 13pt one at the bottom; in one
/// 165pt-wide column the two brand tiles were redundant, and the bottom one was smaller than the neighboring nav icons' 20pt slot.
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

    /// Fixed sidebar width. Usable row width = 165 − 8×2 (outer) − 8×2 (inside the button) = 133pt,
    /// the hard upper bound for enlarging any icon/label.
    static let width: CGFloat = 165

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            Divider().padding(.vertical, 4).padding(.horizontal, 2)
            // The item area must scroll. `MainWindowController` uses `hosting.sizingOptions = []`
            // -- overflowing content is **clipped** rather than growing the window, and
            // `window.minSize` 540 is the frame height including the title bar (the content area is
            // only ~512). Measured: 12 items + 5 group labels + brand footer leave only a dozen or
            // so pt of slack at 512; one more group or a larger system font size would clip the
            // footer. Wrapped in a ScrollView nothing can be clipped no matter how many groups;
            // with slack the content naturally hugs the top.
            ScrollView(.vertical, showsIndicators: false) {
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
                            .font(.system(size: 9.5, weight: .medium))
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

    /// The top keeps only the wordmark (the brand tile is consolidated at the bottom, no longer two
    /// per column)
    private var header: some View {
        HStack(spacing: 7) {
            Text("lulu-lumei-dock")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
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
                        .font(.system(size: 10, weight: .medium))
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
