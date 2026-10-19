import EurekaIngest
import EurekaKit
import SwiftUI

/// Theme shadow helpers: brutal = zero-blur offset ink shadow (brutalist); classic / palette themes
/// = no shadow (unchanged).
extension View {
    /// Card-level shadow (4/4)
    @ViewBuilder
    func themeCardShadow() -> some View {
        if let shadow = Theme.cardShadow {
            self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
        } else {
            self
        }
    }

    /// Small-control shadow (2/2); not drawn when active = false (e.g. an unselected capsule)
    @ViewBuilder
    func themeControlShadow(active: Bool = true) -> some View {
        if active, let shadow = Theme.controlShadow {
            self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
        } else {
            self
        }
    }
}

/// Unified section card: optional title + neutral rounded container (shared by every main-window
/// tab). Replaces the colored cardFill / settingCard / card helpers each tab had before the
/// redesign.
struct SectionCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(Theme.font.themed(13, .semibold))
            }
            VStack(alignment: .leading, spacing: Theme.spacing.row) {
                content
            }
            .padding(Theme.spacing.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.card)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.card)
                            .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth)
                    )
                    .themeCardShadow()
            )
        }
    }
}

/// Capsule sub-tab on a grey tray: selected = brand fill + white text; unselected = grey text with
/// a slight hover highlight. Shared by the main-window tab bar / Settings sub-sections / dashboard
/// sub-tabs.
struct CapsuleTabButton: View {
    let title: String
    var icon: String?
    /// Icon tile background (sidebar-style small colored square; nil = icon follows the text color)
    var tileColor: Color?
    /// true = split the parent evenly (main-window tab bar); false = size to content (sub-tab bars)
    var fillWidth = true
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if let icon {
                    if let tileColor {
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(tileColor.gradient)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Image(systemName: icon)
                                    .font(Theme.font.themed(7.5, .semibold))
                                    .foregroundStyle(.white))
                    } else {
                        Image(systemName: icon)
                            .font(Theme.font.themed(10, .semibold))
                    }
                }
                // Empty title = icon-only mode (as with three-mode `LayoutToggle`): drop the Text
                // too, otherwise the HStack spacing leaves asymmetric blank space next to the icon
                if !title.isEmpty {
                    Text(title)
                        .font(Theme.font.themed(11, isSelected ? .semibold : .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected ? Theme.onBrand : (hovering ? .primary : .secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(Theme.brand.gradient)
                        : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : .clear))
                    .overlay(
                        Group {
                            if isSelected, let outline = Theme.controlOutline {
                                Capsule().strokeBorder(outline.color, lineWidth: outline.width)
                            }
                        }
                    )
                    .themeControlShadow(active: isSelected)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Capsule tab bar container: grey rounded tray (modeled on System Settings' segmented control).
struct CapsuleTabTray<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 3) { content }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 11).fill(Theme.surfaceSecondary))
    }
}

/// Sidebar nav item: monochrome neutral grey icon by default (the "purple-gold" scheme dropped
/// rainbow tiles) + neutral text; selected = brand-purple rounded capsule with white text and icon;
/// unselected = grey text with a slight hover highlight.
struct SidebarNavButton: View {
    let title: String
    let icon: String
    /// Icon tile background (a value shows a small colored rounded square; nil = monochrome grey
    /// icon)
    var tileColor: Color?
    /// Small trailing badge (e.g. rate-limit percentage); nil hides it
    var badge: String?
    var badgeColor: Color = .secondary
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if let tileColor {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tileColor.gradient)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Image(systemName: icon)
                                .font(Theme.font.themed(10, .semibold))
                                .foregroundStyle(.white)
                        )
                } else {
                    Image(systemName: icon)
                        .font(Theme.font.themed(12, .medium))
                        .frame(width: 20, height: 20)
                }
                Text(title)
                    .font(Theme.font.themed(12, isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(Theme.font.themedMono(9.5, .semibold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Theme.onBrand.opacity(0.9))
                                                    : AnyShapeStyle(badgeColor))
                }
            }
            .foregroundStyle(isSelected ? Theme.onBrand : (hovering ? .primary : .secondary))
            .padding(.horizontal, 8)
            // 4 rather than 5: 12 tabs + 5 group labels + brand footer must fit in the ~512pt
            // content area at minimum window height; saving 2pt per row is 24pt. A 28pt row is
            // still above macOS's minimum clickable sidebar size.
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.sidebar).fill(
                    isSelected
                        ? AnyShapeStyle(Theme.brand.gradient)
                        : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : .clear))
                    .overlay(
                        Group {
                            if isSelected, let outline = Theme.controlOutline {
                                RoundedRectangle(cornerRadius: Theme.radius.sidebar)
                                    .strokeBorder(outline.color, lineWidth: outline.width)
                            }
                        }
                    )
                    .themeControlShadow(active: isSelected)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius.sidebar))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Stat tiles (shared by the Skills / Memory / Plans / Agents pages, click to filter)

/// Top stat tile: big number + source logo/icon + label. Split evenly within an HStack so every
/// CLI's tile is the same size in the UI; selected state gets a brand stroke + light brand fill.
struct StatTile: View {
    let value: String
    var sub: String?
    let label: String
    var icon: String?
    var source: AgentSource?
    let tint: Color
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(Theme.font.themedMono(17, .semibold))
                    if let sub {
                        Text(sub)
                            .font(Theme.font.themedMono(9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 4) {
                    if let icon {
                        Image(systemName: icon)
                            .font(Theme.font.themed(9))
                            .foregroundStyle(tint)
                    }
                    if let source {
                        SourceBadge(source: source, size: 10)
                    }
                    Text(label)
                        .font(Theme.font.themed(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            // Even split: content fills its allotted width, so every tile in the HStack is the same
            // size
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .fill(isSelected ? Theme.brandFill(0.10) : Theme.surface)
                    // Hard shadows go on pure shape layers only: on a composite view containing
                    // text, the text leaves a ghost at the offset
                    .themeControlShadow(active: isSelected))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .strokeBorder(
                        ThemeStyle.current.isHardEdged
                            ? (isSelected || hovering ? Theme.ink : Theme.cardBorder)
                            : (isSelected ? Theme.brand.opacity(0.7)
                                          : (hovering ? Theme.brand.opacity(0.35) : Theme.cardBorder)),
                        lineWidth: ThemeStyle.current.isHardEdged
                            ? Theme.cardBorderWidth
                            : (isSelected ? 1 : 0.5)))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius.container))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Unified knowledge card shell & hover actions (shared by the Skills / Memory / Plans / Agents card grids)

/// Card action: icon button that appears on hover (Edit / Finder / Delete). destructive turns red
/// when hovered itself.
struct CardAction: Identifiable {
    let id = UUID()
    let icon: String
    var destructive = false
    var help: String?
    let action: () -> Void
}

/// A single glyph button in the hover action cluster: neutral grey by default, highlighted when
/// hovered itself (delete → failure red).
private struct CardGlyphButton: View {
    let action: CardAction
    @State private var hovering = false

    var body: some View {
        Button(action: action.action) {
            Image(systemName: action.icon)
                .font(Theme.font.themed(10.5, .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(action.help ?? "")
    }

    private var tint: Color {
        if hovering { return action.destructive ? Theme.failureRed : .primary }
        return .secondary
    }
}

/// Action cluster that appears on hover (frosted-glass capsule backing, floating above the card's
/// bottom-right meta).
private struct KnowledgeCardActions: View {
    let actions: [CardAction]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(actions) { CardGlyphButton(action: $0) }
        }
        .padding(.horizontal, 2)
        .background(Capsule(style: .continuous).fill(.regularMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
    }
}

/// Unified knowledge card shell: neutral fill + card radius + soft shadow + hover stroke; disabled
/// state fades the whole card; **no color spine**; clicking the card opens detail; action buttons
/// are hidden by default and fade in at the bottom-right on hover; the context menu is passed in by
/// callers per page. Recommended content layout: `title row (icon + name + trailing accessory) →
/// description/subtitle → Spacer → meta row`.
struct KnowledgeCard<Content: View, Menu: View>: View {
    var enabled = true
    /// Minimum height: 0 = size to content (grid rows equalize automatically), avoiding hollow
    /// middles from a fixed height
    var minHeight: CGFloat = 0
    var actions: [CardAction] = []
    let onOpen: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var menu: () -> Menu

    @State private var hovering = false

    var body: some View {
        let hardEdged = ThemeStyle.current.isHardEdged
        content()
            .padding(12)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            // brutal dims the content and keeps the fill opaque, so the hard shadow underneath can
            // never show through a disabled card; classic keeps dimming the fill as it always did.
            .opacity(hardEdged && !enabled ? 0.6 : 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.card)
                    .fill(Theme.surface)
                    .opacity(!hardEdged && !enabled ? 0.6 : 1))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.card)
                    .strokeBorder(
                        hardEdged
                            ? (hovering ? Theme.ink : Theme.cardBorder)
                            : (hovering ? Theme.brand.opacity(0.6) : Theme.cardBorder),
                        lineWidth: hardEdged ? Theme.cardBorderWidth : (hovering ? 1 : 0.5)))
            .overlay(alignment: .bottomTrailing) {
                if hovering, !actions.isEmpty {
                    KnowledgeCardActions(actions: actions)
                        .padding(7)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius.card))
            // brutal hard shadow: a pure ink shape offset 4/4 *behind* the clipped card, not
            // `.shadow` on the composite — that one was cast by the text too and ghosted every
            // glyph of a disabled card 4pt away. Nothing is added here for classic.
            .background {
                if let shadow = Theme.cardShadow {
                    RoundedRectangle(cornerRadius: Theme.radius.card)
                        .fill(shadow.color)
                        .offset(x: shadow.x, y: shadow.y)
                }
            }
            .shadow(
                color: hardEdged ? .clear : .black.opacity(0.06),
                radius: hardEdged ? 0 : 3,
                y: hardEdged ? 0 : 1.5)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius.card))
            .onTapGesture { onOpen() }
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
            .contextMenu { menu() }
    }
}

// MARK: - Unified small tag / status dot / empty state / search field / section header / document card

/// Unified small tag (project name = gold; neutral = grey). Replaces the project chip / "read-only"
/// / "built-in" pills copied across pages.
struct TagChip: View {
    let text: String
    var tint: Color = Theme.goldFg
    var neutral = false

    init(_ text: String, tint: Color = Theme.goldFg, neutral: Bool = false) {
        self.text = text
        self.tint = tint
        self.neutral = neutral
    }

    var body: some View {
        Text(text)
            .font(Theme.font.themed(9, .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(neutral ? Color.primary.opacity(0.06) : tint.opacity(0.15)))
            .foregroundStyle(neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
    }
}

/// Small enable dot (restrained green = enabled / grey = disabled), click to toggle; replaces the
/// saturated green square.
struct StatusDot: View {
    let enabled: Bool
    var size: CGFloat = 9
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Circle()
                .fill(enabled ? Theme.enabledGreen.opacity(0.9) : Color.secondary.opacity(0.4))
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(enabled
            ? L10n.text("Enabled (click to disable)", zhHans: "已启用（点击停用）")
            : L10n.text("Disabled (click to enable)", zhHans: "已停用（点击启用）"))
    }
}

/// Unified empty state: faint brand-colored icon + title + optional hint + optional primary action
/// button (shared by four pages).
struct EmptyStateView: View {
    let icon: String
    let title: String
    var hint: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(Theme.font.themed(34))
                .foregroundStyle(Theme.brandFg.opacity(0.5))
            Text(title)
                .font(Theme.font.themed(12))
                .foregroundStyle(.secondary)
            if let hint {
                Text(hint)
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Unified search field (purple-gold signature version): purple-gold gradient magnifier tile +
/// capsule fill + purple-gold gradient ring and glow when focused; while searching, a hit-count
/// capsule + round clear button show at the right. Shared by four pages (source filtering is
/// handled by the chips below).
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var scanning = false
    /// Hit count (shown at the right while searching; nil = hidden)
    var resultCount: Int?
    /// Max width: in the mockup the search field is medium width, not full-row (nil = decided by
    /// the parent)
    var maxWidth: CGFloat? = 460

    @FocusState private var focused: Bool
    @State private var hovering = false

    private var searching: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 9) {
            glyph
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.font.themed(12.5))
                .tint(Theme.brand)  // purple caret and selection
                .focused($focused)
            if scanning { ProgressView().controlSize(.mini) }
            trailing
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: maxWidth)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    Capsule(style: .continuous)
                        .fill(Theme.brandFill(focused ? 0.10 : (hovering ? 0.06 : 0.035))))
                // Hard shadows go on pure shape layers only: on a composite view containing text,
                // the text leaves a ghost at the offset
                .themeControlShadow())
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    ThemeStyle.current.isHardEdged
                        ? AnyShapeStyle(Theme.ink)
                        : AnyShapeStyle(LinearGradient(
                            colors: [Theme.brand.opacity(focused ? 1 : 0.5),
                                     Theme.gold.opacity(focused ? 1 : 0.5)],
                            startPoint: .leading, endPoint: .trailing)),
                    lineWidth: ThemeStyle.current.isHardEdged
                        ? (focused ? Theme.cardBorderWidth + 0.5 : max(1, Theme.cardBorderWidth - 0.5))
                        : (focused ? 1.8 : 1)))
        .shadow(
            color: ThemeStyle.current.isHardEdged ? .clear : Theme.brand.opacity(focused ? 0.22 : 0),
            radius: ThemeStyle.current.isHardEdged ? 0 : 10,
            y: ThemeStyle.current.isHardEdged ? 0 : 2)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: focused)
        .animation(.easeOut(duration: 0.16), value: hovering)
    }

    /// Brand gradient magnifier tile (same tile language as the brand mark / logo tiles; gold is
    /// reserved for the focus ring). Themed styles = flat brand-colored tile + each style's stroke
    /// and shadow.
    private var glyph: some View {
        RoundedRectangle(
            cornerRadius: ThemeStyle.current.isHardEdged ? Theme.radius.tile : 7, style: .continuous)
            .fill(Theme.brandTileGradient)
            // The hard shadow is drawn before overlaying the magnifier icon: it takes only the tile
            // outline, so the icon leaves no ghost at the offset
            .themeControlShadow()
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: "magnifyingglass")
                    .font(Theme.font.themed(11.5, .bold))
                    .foregroundStyle(Theme.onBrand))
            .overlay(
                Group {
                    if let outline = Theme.controlOutline {
                        RoundedRectangle(cornerRadius: Theme.radius.tile, style: .continuous)
                            .strokeBorder(outline.color, lineWidth: max(1, outline.width - 0.5))
                    }
                }
            )
            .shadow(
                color: ThemeStyle.current.isHardEdged ? .clear : Theme.brand.opacity(focused ? 0.38 : 0.18),
                radius: ThemeStyle.current.isHardEdged ? 0 : 3,
                y: ThemeStyle.current.isHardEdged ? 0 : 1)
    }

    @ViewBuilder private var trailing: some View {
        if searching {
            if let resultCount {
                Text("\(resultCount)")
                    .font(Theme.font.themedMono(10.5, .semibold))
                    .foregroundStyle(Theme.brandFg)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.brandFill(0.14)))
                    .help(L10n.text("Number of matches", zhHans: "匹配项数量"))
            }
            Button { text = "" } label: {
                Image(systemName: "xmark")
                    .font(Theme.font.themed(9, .bold))
                    .foregroundStyle(Theme.brandFg)
                    .frame(width: 19, height: 19)
                    .background(Circle().fill(Theme.brandFill(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("Clear search", zhHans: "清空搜索"))
        }
    }
}

/// Unified source section header: disclosure arrow + source logo/gold icon + title + optional
/// subtitle + neutral count + optional note + full-width divider. Consolidates three duplicate
/// implementations from Skills / Memory / Plans / Agents (count unified as a neutral grey capsule,
/// dropping the gold/purple inconsistency).
struct SourceSectionHeader: View {
    var source: AgentSource?
    var icon: String?
    let title: String
    var subtitle: String?
    let count: Int
    var trailingNote: String?
    let collapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onToggle) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(Theme.font.themed(9, .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    if let source {
                        SourceBadge(source: source, size: 12)
                    } else if let icon {
                        Image(systemName: icon)
                            .font(Theme.font.themed(11))
                            .foregroundStyle(Theme.goldFg)
                    }
                    Text(title)
                        .font(Theme.font.themed(12, .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.font.themed(11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Text("\(count)")
                        .font(Theme.font.themedMono(10, .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.surfaceSecondary))
                    if let trailingNote {
                        Text(trailingNote)
                            .font(Theme.font.themed(10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack { Divider() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Unified Markdown document card for detail pages (width-limited and centered + generous padding).
/// Shared by four detail pages, replacing copy-pasted card blocks.
struct MarkdownDocumentCard: View {
    let text: String

    var body: some View {
        ScrollView {
            MarkdownRichText(text: text)
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius.card)
                        .fill(Theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius.card)
                                .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
                        .themeCardShadow())
                .frame(maxWidth: .infinity)
                .padding(Theme.spacing.page)
        }
    }
}

// MARK: - Small controls shared by cards / list rows / detail toolbars
// (previously scattered in SkillMemoryView.swift, consolidated here so the Skills / Memory / Plans / Agents pages can share them)

/// Unified tile spec: light tinted fill + light stroke in the same color + radius 8 (the reference
/// mockup's minimal style). Logo tiles / plan icon tiles all render with this spec so tiles stay
/// consistent site-wide.
struct TileSpec {
    /// Fill color (tint 10%)
    static func fill(_ tint: Color, hovering: Bool = false) -> Color {
        tint.opacity(hovering ? 0.18 : 0.10)
    }
    /// Stroke (tint 16%)
    static func border(_ tint: Color) -> Color {
        tint.opacity(0.16)
    }
    /// Corner radius: ≈ 8 for a 26pt tile, shrinking slightly with size
    static func radius(_ size: CGFloat) -> CGFloat {
        min(Theme.radius.tile, size * 0.32)
    }
}

/// 26×26 purple-fill light-framed logo tile (shared by skill cards / list rows / detail toolbars)
struct SourceLogoTile: View {
    let source: AgentSource
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
            .fill(TileSpec.fill(Theme.brand))
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
                    .strokeBorder(
                        ThemeStyle.current.isHardEdged ? Theme.cardBorder : TileSpec.border(Theme.brand),
                        lineWidth: ThemeStyle.current.isHardEdged ? Theme.cardBorderWidth : 0.5))
            .overlay(SourceBadge(source: source, size: size * 0.55))
    }
}

/// Mini enable switch (30×17): green = on / grey = off, knob right/left; shared by skill cards /
/// list rows / detail toolbars
struct MiniSwitch: View {
    let isOn: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Capsule()
                .fill(isOn ? Theme.enabledGreen : Theme.disabledGray)
                .frame(width: 30, height: 17)
                .overlay(
                    Group {
                        if let outline = Theme.controlOutline {
                            Capsule().strokeBorder(
                                outline.color, lineWidth: max(1, outline.width - 0.5))
                        }
                    }
                )
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Theme.controlKnob)
                        .shadow(
                            color: ThemeStyle.current.isHardEdged ? .clear : .black.opacity(0.18),
                            radius: ThemeStyle.current.isHardEdged ? 0 : 1,
                            y: ThemeStyle.current.isHardEdged ? 0 : 0.5)
                        .overlay(
                            Group {
                                if let outline = Theme.controlOutline {
                                    Circle().strokeBorder(
                                        outline.color, lineWidth: max(1, outline.width - 0.5))
                                }
                            }
                        )
                        .frame(width: 13, height: 13)
                        .padding(2)
                }
        }
        .buttonStyle(.plain)
        .help(isOn
            ? L10n.text("Enabled (click to disable)", zhHans: "已启用（点击停用）")
            : L10n.text("Disabled (click to enable)", zhHans: "已停用（点击启用）"))
    }
}

/// Toggle style for every on/off setting: classic delegates to the system switch (so classic
/// is pixel-identical to `.toggleStyle(.switch)`), brutal draws the label followed by the
/// ink-outlined MiniSwitch used on list rows, instead of a system-blue switch.
struct ThemedSwitchToggleStyle: ToggleStyle {
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if ThemeStyle.current.isHardEdged {
            BrutalSwitchRow(configuration: configuration)
        } else {
            SwitchToggleStyle().makeBody(configuration: configuration)
        }
    }
}

extension ToggleStyle where Self == ThemedSwitchToggleStyle {
    static var themedSwitch: ThemedSwitchToggleStyle { ThemedSwitchToggleStyle() }
}

private struct BrutalSwitchRow: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 8) {
            configuration.label
            MiniSwitch(isOn: configuration.isOn) { configuration.isOn.toggle() }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Enable state text (enabled green / disabled grey) + mini switch (for detail toolbars / list
/// rows; card faces use only MiniSwitch)
struct EnableToggle: View {
    let enabled: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(enabled
                ? L10n.text("Enabled", zhHans: "已启用")
                : L10n.text("Disabled", zhHans: "已停用"))
                .font(Theme.font.themed(9.5, .medium))
                .foregroundStyle(enabled ? Theme.enabledGreen : .secondary)
            MiniSwitch(isOn: enabled, onToggle: onToggle)
        }
    }
}

/// Card action icon button (edit/folder/delete): neutral minimal style -- light grey fill + thin
/// grey border + grey icon, only delete uses a red icon (no red fill); hover darkens the fill. Used
/// where actions are always shown, like list rows / detail.
struct CardActionButton: View {
    let icon: String
    var color: Color = .secondary
    var size: CGFloat = 24
    var help: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
                .overlay(
                    RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
                        .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
                .contentShape(RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

// MARK: - Layout toggle (cards / list; shared by the Skills / Memory / Plans / Agents pages)

/// Knowledge view mode: full-width list / icons (card grid). Order is the segmented control order
/// (list on the left, default).
enum KnowledgeLayout: String, CaseIterable {
    case list = "列表"
    case cards = "图标"
    /// Relation graph: currently only the Memory page has one (memories have `[[links]]` between
    /// them and point at origin sessions; skills/plans/agents have no such relations, so giving
    /// them this mode would only show an empty graph)
    case graph = "图谱"

    var title: String {
        switch self {
        case .list: return L10n.text("List", zhHans: "列表")
        case .cards: return L10n.text("Icons", zhHans: "图标")
        case .graph: return L10n.text("Graph", zhHans: "图谱")
        }
    }

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .cards: return "square.grid.2x2"
        case .graph: return "point.3.filled.connected.trianglepath.dotted"
        }
    }

    /// Pages with a relation graph use it; other pages use `withoutGraph`
    static let withoutGraph: [KnowledgeLayout] = [.list, .cards]
}

/// The "cards / list / graph" segmented toggle at the right of the top toolbar (same style as
/// segmented controls site-wide). `cases` comes from the caller: pages with no relations to draw
/// shouldn't grow a graph mode out of nowhere.
struct LayoutToggle: View {
    @Binding var layout: KnowledgeLayout
    var cases: [KnowledgeLayout] = KnowledgeLayout.withoutGraph

    var body: some View {
        // Icons only with three modes: the top bar is already tight at the minimum window width
        // (840), and labels would squeeze "List" into an ellipsis
        let iconOnly = cases.count > 2
        CapsuleTabTray {
            ForEach(cases, id: \.self) { item in
                CapsuleTabButton(
                    title: iconOnly ? "" : item.title, icon: item.icon, fillWidth: false,
                    isSelected: layout == item
                ) { layout = item }
                    .help(item.title)
            }
        }
    }
}

/// Scan status label (shared by the Skills / Memory / Plans / Agents top bars, right next to the
/// refresh button).
///
/// Why it's needed: these four pages are scanned in the background at app launch, and entering a page no longer scans blindly -- so "is it scanning right now"
/// and "how old is the data" must be said explicitly. Previously `scanning` only showed as a mini spinner in the search field and in the
/// **empty state** copy; once the list had data, a rescan was nearly invisible. And since there's
/// no file-system watching (externally added skills don't appear automatically), "last scanned X
/// ago" is the user's only basis for deciding whether to refresh.
struct ScanStatusLabel: View {
    let scanning: Bool
    /// Scan phase text (Plans switches between materializing/indexing)
    var phase: String?
    var lastScanAt: Date?

    var body: some View {
        if scanning {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(phase ?? L10n.text("Scanning…", zhHans: "正在扫描…"))
                    .font(Theme.font.themed(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .transition(.opacity)
        } else if let lastScanAt {
            Text(L10n.format("Last scan %@", zhHans: "上次扫描 %@", relativeLabel(lastScanAt)))
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help(L10n.text("Opening the page no longer rescans. Click refresh to force a full rescan.", zhHans: "进页面不再自动重扫；点刷新可强制全量重扫"))
        }
    }
}

/// Unified refresh button: purple icon + faint purple round fill (shared by the management page top
/// bars). Visible but compact -- as a secondary action it doesn't compete with the "New" text
/// capsule.
struct RefreshButton: View {
    var help = L10n.text("Refresh", zhHans: "刷新")
    let action: () -> Void

    var body: some View {
        RoundGlyphButton(icon: "arrow.clockwise", help: help, action: action)
    }
}

/// The round toolbar button RefreshButton is made of: 26pt circle, brand-tinted glyph on a
/// light brand fill with a thin brand stroke. `active` flips it to a solid brand fill for
/// toggles (multi-select on the sessions page), so a toggle and the refresh button next to it
/// are one shape instead of a square beside a circle.
struct RoundGlyphButton: View {
    let icon: String
    var active = false
    var help = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(Theme.font.themed(11, .semibold))
                .foregroundStyle(RoundGlyphChrome.glyph(active: active))
                .modifier(RoundGlyphChrome(active: active, hovering: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Round glyph that opens a menu ("+" new-item menus). The circle is drawn on the Menu view
/// itself: the borderless menu style does not paint backgrounds placed inside its label, which
/// is why the old "+" menus showed a bare glyph next to a fully drawn refresh button.
struct RoundGlyphMenu<Items: View>: View {
    let icon: String
    var help = ""
    @ViewBuilder var items: () -> Items

    @State private var hovering = false

    var body: some View {
        Menu(content: items) {
            Image(systemName: icon)
                .font(Theme.font.themed(12, .semibold))
                .foregroundStyle(RoundGlyphChrome.glyph(active: false))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(RoundGlyphChrome(active: false, hovering: hovering))
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 26pt circle shared by RoundGlyphButton / RoundGlyphMenu. Hard-edged styles speak in 2px ink
/// outlines, flat fills and offset hard shadows; the classic branch keeps the light brand tint
/// it always had. The shadow is painted on the circle only, never on the glyph.
private struct RoundGlyphChrome: ViewModifier {
    let active: Bool
    let hovering: Bool

    static func glyph(active: Bool) -> Color {
        active ? Theme.onBrand : (ThemeStyle.current.isHardEdged ? Theme.ink : Theme.brandFg)
    }

    func body(content: Content) -> some View {
        let hard = ThemeStyle.current.isHardEdged
        let fill: AnyShapeStyle = active
            ? AnyShapeStyle(Theme.brand)
            : (hard
                ? AnyShapeStyle(hovering ? Theme.surfaceSecondary : Theme.surface)
                : AnyShapeStyle(Theme.brandFill(hovering ? 0.18 : 0.10)))
        let stroke: Color = hard ? Theme.ink : (active ? Theme.brand : Theme.brand.opacity(0.35))
        content
            .frame(width: 26, height: 26)
            .background(Circle().fill(fill).themeControlShadow(active: hard))
            .overlay(Circle().strokeBorder(stroke, lineWidth: hard ? Theme.cardBorderWidth : 0.8))
            .contentShape(Circle())
    }
}

// MARK: - Action buttons / count chip / pane header (the brutal vocabulary system controls lack)
//
// Pages used to reach for SwiftUI's own buttons, menus and chips, which have no hard-edged
// branch: under brutal they stayed classic (thin bezels, soft fills, SF type). These wrappers
// keep the exact system styling in classic — so classic stays pixel-identical — and draw the
// brutal form themselves: capsule, 2px ink outline, flat fill, 2/2 hard shadow on the shape.

/// Capsule label shared by the brutal branches of the buttons below
private struct BrutalCapsuleLabel: View {
    let title: String
    var icon: String?
    var trailingIcon: String?
    let fill: Color
    let foreground: Color
    var shadow = true

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(Theme.font.themed(10, .semibold))
            }
            Text(title).font(Theme.font.themed(11, .semibold)).lineLimit(1)
            if let trailingIcon {
                Image(systemName: trailingIcon).font(Theme.font.themed(8, .bold)).opacity(0.7)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(fill).themeControlShadow(active: shadow))
        .overlay(Capsule().strokeBorder(Theme.ink, lineWidth: Theme.cardBorderWidth))
        .contentShape(Capsule())
    }
}

/// Primary action (one per toolbar): classic = `.borderedProminent` tinted brand, small; brutal =
/// solid brand capsule with ink text, ink outline and hard shadow.
struct PrimaryButton: View {
    let title: String
    var icon: String?
    var help: String?
    /// Attached to the inner Button so it works in both branches (e.g. ⌘S on Save)
    var shortcut: KeyboardShortcut?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if ThemeStyle.current.isHardEdged {
            Button(action: action) {
                BrutalCapsuleLabel(
                    title: title, icon: icon, fill: Theme.brand, foreground: Theme.onBrand)
                    .opacity(isEnabled ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(shortcut)
            .help(help ?? "")
        } else {
            Button(action: action) {
                systemLabel(title: title, icon: icon)
            }
            .keyboardShortcut(shortcut)
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(Theme.brand)
            .help(help ?? "")
        }
    }
}

/// Secondary action: classic = `.bordered` small (red-tinted when destructive); brutal = flat
/// surface capsule with ink outline and hard shadow, red text when destructive.
struct SecondaryButton: View {
    /// What the classic branch reproduces: `.bordered` (toolbars) or the default push button
    /// (inline actions in forms and rows), so swapping a call site never changes classic
    enum ClassicLook { case bordered, push }

    let title: String
    var icon: String?
    var destructive = false
    var classic: ClassicLook = .bordered
    var help: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        if ThemeStyle.current.isHardEdged {
            Button(action: action) {
                BrutalCapsuleLabel(
                    title: title, icon: icon,
                    fill: hovering ? Theme.surfaceSecondary : Theme.surface,
                    foreground: destructive ? Theme.failureRed : Theme.ink)
                    .opacity(isEnabled ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help ?? "")
        } else if classic == .push {
            Button(action: action) {
                if let icon {
                    Label(title, systemImage: icon)
                } else {
                    Text(title)
                }
            }
            .controlSize(.small)
            .help(help ?? "")
        } else {
            Button(action: action) {
                systemLabel(title: title, icon: icon)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .tint(destructive ? .red : nil)
            .help(help ?? "")
        }
    }
}

/// Dropdown of actions: classic = the borderless system menu button the pages had; brutal = a
/// SecondaryButton-shaped capsule with a ▾. The capsule is drawn on the Menu view itself, not
/// inside its label, because the borderless menu style does not paint label backgrounds.
struct MenuButton<Items: View>: View {
    let title: String
    var icon: String?
    var help: String?
    @ViewBuilder var items: () -> Items

    var body: some View {
        if ThemeStyle.current.isHardEdged {
            Menu(content: items) {
                HStack(spacing: 5) {
                    if let icon {
                        Image(systemName: icon).font(Theme.font.themed(10, .semibold))
                    }
                    Text(title).font(Theme.font.themed(11, .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(Theme.font.themed(8, .bold)).opacity(0.7)
                }
                .foregroundStyle(Theme.ink)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Theme.surface).themeControlShadow())
            .overlay(Capsule().strokeBorder(Theme.ink, lineWidth: Theme.cardBorderWidth))
            .help(help ?? "")
        } else {
            Menu(content: items) {
                systemLabel(title: title, icon: icon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(help ?? "")
        }
    }
}

/// The 11pt system `Label` the session page's toolbar buttons were built from (classic branch)
@ViewBuilder
private func systemLabel(title: String, icon: String?) -> some View {
    if let icon {
        Label(title, systemImage: icon).font(Theme.font.themed(11))
    } else {
        Text(title).font(Theme.font.themed(11))
    }
}

/// Small count next to a pane title (the transcript pane shows "Transcript 19"): classic = brand-tinted pill; brutal =
/// ink-outlined capsule with a Space Mono number.
struct CountChip: View {
    let text: String

    init(_ text: String) { self.text = text }
    init(_ count: Int) { self.text = count.formatted() }

    var body: some View {
        let hard = ThemeStyle.current.isHardEdged
        Text(text)
            .font(Theme.font.themedMono(10.5, .medium))
            .foregroundStyle(hard ? Theme.ink : Theme.brandFg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(hard ? Theme.surface : Theme.brandFill(0.12)))
            .overlay(
                Group {
                    if hard { Capsule().strokeBorder(Theme.ink, lineWidth: 1.5) }
                })
    }
}

/// Pane / section header: glyph + title in the themed face, then whatever the caller puts
/// after it (count chip, hints); the caller owns padding and the trailing Spacer.
struct PaneHeader<Trailing: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(icon: String, title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.icon = icon
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(Theme.font.themed(11, .medium))
                .foregroundStyle(ThemeStyle.current.isHardEdged ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(.secondary))
            Text(title)
                .font(Theme.font.themed(12, .semibold))
            trailing()
        }
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(icon: String, title: String) {
        self.init(icon: icon, title: title) { EmptyView() }
    }
}

/// lulu-lumei-dock brand mark: purple-gold gradient rounded tile + gold "Lu" outline (LuluMark,
/// same source as the Dock icon). Shared by the sidebar's bottom brand area / the Settings → About
/// card, scaled proportionally by size.
///
/// Proportions are **all converted from `AppIconView`'s 1024 master** (`IconRenderer.swift:44-95`).
/// This used to be a separate set of hand-tuned values: the wordmark took only `0.42` of the height (the master is `430/824 ≈ 0.522`),
/// the gold was a flat color instead of a three-stop gradient, and there was no top-left white highlight or shadow -- enlarged it was just a flat square.
///
/// The only two deviations from the master (both deliberate):
///  - The highlight stroke and shadow convert to `0.007×size` / `0.034×size`, under 0.2pt at 26pt,
///    which can't draw a line even on 2x displays → given a floor and scaled by size until visible;
///  - The master has 100px of transparent margin around its 824 plate (the shadow is drawn in it);
///    here `size` is the plate itself.
struct LuluLogoTile: View {
    var size: CGFloat = 26

    /// Master: glyph height 430 / plate 824
    private var glyphHeight: CGFloat { size * 0.522 }
    /// Master: stroke width = glyph height / φ³
    private var stroke: CGFloat { max(1, glyphHeight * 0.2361) }
    private var corner: CGFloat { size * 0.2237 }

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.55, green: 0.55, blue: 0.96),
                        Color(red: 0.36, green: 0.36, blue: 0.89),
                        Color(red: 0.16, green: 0.13, blue: 0.45),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            // Warm gold glow at the center, lifting the gold wordmark (master: 640/824 diameter,
            // 300/824 radius)
            .overlay(
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 1.0, green: 0.9, blue: 0.6).opacity(0.18), .clear,
                            ],
                            center: .center, startRadius: 0, endRadius: size * 0.364))
                    .frame(width: size * 0.777, height: size * 0.777))
            .overlay(
                LuluMark()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 0.98, green: 0.87, blue: 0.55),
                                Color(red: 0.89, green: 0.74, blue: 0.38),
                                Color(red: 0.76, green: 0.58, blue: 0.18),
                            ],
                            startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(
                            lineWidth: stroke, lineCap: .round, lineJoin: .round))
                    // Full width: LuluMark centers itself horizontally in its rect (the master also
                    // gives it the full plate width)
                    .frame(width: size, height: glyphHeight)
                    .shadow(
                        color: Color(red: 0.10, green: 0.07, blue: 0.30).opacity(0.45),
                        radius: size * 0.035, y: size * 0.025))
            // Top-left white highlight stroke: turns a flat tinted tile into a solid with thickness
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.42), .white.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: max(0.75, size * 0.015)))
            .shadow(color: .black.opacity(0.28), radius: size * 0.045, y: size * 0.022)
    }
}

// MARK: - Unified knowledge list row (shared by list mode, modeled on the Sessions page's SessionRow)

/// Refined full-width row: content slot (logo at left + two lines of text + status at right) +
/// actions that appear on hover; hover highlight + thin purple bar on the left edge; clicking the
/// row opens detail; the context menu is passed in by callers per page. Recommended content layout:
/// `HStack { icon; VStack{ title row; description row }; Spacer; trailing accessory }`.
struct KnowledgeRow<Content: View, Menu: View>: View {
    var enabled = true
    var actions: [CardAction] = []
    let onOpen: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var menu: () -> Menu

    @State private var hovering = false

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .opacity(enabled ? 1 : 0.6)
            .background(
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(hovering ? Theme.brandFill(0.06) : Color.clear)
                    if hovering {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Theme.brand)
                            .frame(width: 3)
                            .padding(.vertical, 5)
                    }
                })
            .overlay(alignment: .trailing) {
                if hovering, !actions.isEmpty {
                    KnowledgeCardActions(actions: actions)
                        .padding(.trailing, 8)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen() }
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
            .contextMenu { menu() }
    }
}

/// List-mode group container: white rounded card + thin stroke + soft shadow, gathering a section's
/// rows into one "table" card (macOS System Settings-style grouped list); dividers are indented by
/// callers to where the row text starts.
struct KnowledgeListContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                    .fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous))
            .shadow(
                color: ThemeStyle.current.isHardEdged ? .clear : .black.opacity(0.05),
                radius: ThemeStyle.current.isHardEdged ? 0 : 3,
                y: ThemeStyle.current.isHardEdged ? 0 : 1.5)
            .themeCardShadow()
    }
}

// MARK: - Purple-gold redesign: stats overview card / source filter chips / flow layout

/// Wrapping flow layout (chips wrap automatically when too wide; macOS 13+ Layout protocol).
struct FlowLayout: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(maxWidth, widest), height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Top stats overview card: left "big number + unit + subtitle", vertical divider, right
/// "distribution title + optional stacked segment bar + legend". Shared by four pages; Agents
/// passes `showBar: false` (only a model distribution legend, no bar). Structural colors are
/// semantic/brand only.
struct StatOverviewCard: View {
    struct Segment: Identifiable {
        let id = UUID()
        let label: String
        let count: Int
        let color: Color
    }

    let value: String
    let unit: String
    var subtitle: String?
    let distributionTitle: String
    let segments: [Segment]
    var showBar = true
    var trailingNote: String?

    private var total: Int { max(1, segments.reduce(0) { $0 + $1.count }) }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value).font(Theme.font.statNumber(28))
                    Text(unit).font(Theme.font.themed(12.5, .medium)).foregroundStyle(.secondary)
                }
                if let subtitle {
                    Text(subtitle).font(Theme.font.themedMono(11)).foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 120, alignment: .leading)

            Rectangle().fill(Theme.hairline).frame(width: 1, height: 46)

            VStack(alignment: .leading, spacing: 9) {
                Text(distributionTitle)
                    .font(Theme.font.themed(12, .semibold))
                    .foregroundStyle(.secondary)
                if showBar {
                    GeometryReader { geo in
                        HStack(spacing: 1.5) {
                            ForEach(segments.filter { $0.count > 0 }) { seg in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(seg.color)
                                    .frame(width: barWidth(seg, in: geo.size.width))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(Capsule())
                    }
                    .frame(height: 8)
                }
                HStack(spacing: 14) {
                    ForEach(segments) { seg in
                        HStack(spacing: 5) {
                            Circle().fill(seg.color).frame(width: 8, height: 8)
                            Text(seg.label).font(Theme.font.themed(11)).foregroundStyle(.secondary)
                            Text("\(seg.count)")
                                .font(Theme.font.themedMono(11, .semibold))
                        }
                        // Fallback: with too many legend items, overflow and clip the whole thing
                        // rather than letting a label or "16,911" fold vertically one character per
                        // line (the audit page's 9 ToolKinds really hit this shape). Trimming is
                        // the caller's job (fold into "top 4 + other" like AgentsView does).
                        .lineLimit(1)
                        .fixedSize()
                    }
                    Spacer(minLength: 8)
                    if let trailingNote {
                        Text(trailingNote).font(Theme.font.themedMono(11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.card)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.card)
                        .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
                .themeCardShadow())
        .shadow(
            color: ThemeStyle.current.isHardEdged ? .clear : .black.opacity(0.05),
            radius: ThemeStyle.current.isHardEdged ? 0 : 2,
            y: ThemeStyle.current.isHardEdged ? 0 : 1)
    }

    private func barWidth(_ seg: Segment, in width: CGFloat) -> CGFloat {
        let usable = width - CGFloat(max(0, segments.filter { $0.count > 0 }.count - 1)) * 1.5
        return max(3, usable * CGFloat(seg.count) / CGFloat(total))
    }
}

/// Source filter chip: nil = all (uses the page's icon); otherwise shows source logo + name +
/// count. Selected = brand-purple fill + white text; unselected = white fill + thin border, slight
/// tint on hover.
struct SourceFilterChip: View {
    var source: AgentSource?
    var allIcon: String
    let label: String
    let count: Int
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if let source {
                    SourceBadge(source: source, size: 14)
                } else {
                    Image(systemName: allIcon).font(Theme.font.themed(11, .semibold))
                }
                Text(label)
                    .font(Theme.font.themed(11.5, isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Text("\(count)")
                    .font(Theme.font.themedMono(10.5, .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.onBrand.opacity(0.85))
                                                : AnyShapeStyle(.secondary))
            }
            .foregroundStyle(isSelected ? Theme.onBrand : (hovering ? .primary : .secondary))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(Theme.brand)
                        : AnyShapeStyle(hovering ? Theme.brandFill(0.06) : Theme.surface))
                    // Hard shadows go on pure shape layers only: on a composite view containing
                    // text, the text leaves a ghost at the offset
                    .themeControlShadow(active: isSelected))
            .overlay(
                Capsule().strokeBorder(
                    ThemeStyle.current.isHardEdged
                        ? Theme.cardBorder
                        : (isSelected ? Color.clear : Theme.cardBorder),
                    lineWidth: ThemeStyle.current.isHardEdged ? Theme.cardBorderWidth : 0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Source filter bar: "All" + per-source chips (wrapping). Binds selectedSource (nil = all);
/// clicking the selected one again deselects it.
struct SourceFilterBar: View {
    @Binding var selected: AgentSource?
    let allLabel: String
    let allIcon: String
    let totalCount: Int
    let sources: [AgentSource]
    let count: (AgentSource) -> Int

    var body: some View {
        FlowLayout(spacing: 10, lineSpacing: 10) {
            SourceFilterChip(
                source: nil, allIcon: allIcon, label: allLabel,
                count: totalCount, isSelected: selected == nil
            ) { selected = nil }
            ForEach(sources, id: \.self) { source in
                SourceFilterChip(
                    source: source, allIcon: allIcon, label: source.displayName,
                    count: count(source), isSelected: selected == source
                ) { selected = (selected == source ? nil : source) }
            }
        }
    }
}

// MARK: - Purple-gold redesign: progress ring / progress bar / scope badge / role avatar / role tag / model chip

/// Plans list row progress bar: grey track + purple fill (fixed-width capsule; the % text is added
/// separately by the caller).
struct PlanProgressBar: View {
    let progress: Double
    var width: CGFloat = 88

    var body: some View {
        Capsule().fill(Theme.hairline)
            .frame(width: width, height: 6)
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.brand)
                    .frame(width: max(3, width * progress), height: 6)
            }
    }
}

/// Memory scope badge: global = purple stroke / project = gold stroke (stroked capsule, no solid
/// fill).
struct ScopeBadge: View {
    let isGlobal: Bool

    var body: some View {
        let tint = isGlobal ? Theme.brand : Theme.gold
        Text(isGlobal
            ? L10n.text("Global", zhHans: "全局")
            : L10n.text("Project", zhHans: "项目"))
            .font(Theme.font.themed(9.5, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(tint.opacity(0.65), lineWidth: 1))
    }
}

/// Terminal ownership tag: "iTerm2 · ttys004". Same stroked-capsule spec as ScopeBadge.
///
/// Probe-derived entries (`origin == .probe`) get a dashed stroke and a tooltip noting lower precision -- they're inferred by matching
/// cwd and walking up the process tree, not as certain as hooks; users shouldn't think the two are equally reliable.
struct TerminalBadge: View {
    let binding: TerminalBinding
    /// Whether the terminal app is still running (decides whether to show the greyed "exited"
    /// state)
    var isRunning: Bool = true

    var body: some View {
        let tint: Color = isRunning ? Theme.brand : .secondary
        HStack(spacing: 3) {
            Image(systemName: "terminal")
                .font(Theme.font.themed(8, .semibold))
            Text(binding.displayName)
                .font(Theme.font.themed(9.5, .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay {
            let shape = Capsule()
            if binding.origin == .probe {
                shape.strokeBorder(
                    tint.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
            } else {
                shape.strokeBorder(tint.opacity(0.6), lineWidth: 1)
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        var lines = [binding.origin == .probe
            ? L10n.text("Inferred by matching a running process to the working directory (less precise than a hook)", zhHans: "按工作目录匹配运行中的进程推断（精度低于 hook 采集）")
            : L10n.text("Captured by a hook inside the session's terminal", zhHans: "由 hook 在会话所在终端内采集")]
        if let tty = binding.tty {
            lines.append(L10n.format("Terminal device %@", zhHans: "终端设备 %@", tty))
        }
        if !isRunning {
            lines.append(L10n.text("That terminal app is not running", zhHans: "该终端应用当前未在运行"))
        }
        return lines.joined(separator: "\n")
    }
}

/// Agents role tile: same tile spec as SourceLogoTile (purple-fill light-framed rounded square),
/// with the content swapped for the role's single-character glyph (`AgentRole.glyph`). Tile shape /
/// lines / colors are thus identical across the four pages; role colors stay only on RoleTag.
struct RoleAvatar: View {
    let role: AgentRole
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
            .fill(TileSpec.fill(Theme.brand))
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
                    .strokeBorder(
                        ThemeStyle.current.isHardEdged ? Theme.cardBorder : TileSpec.border(Theme.brand),
                        lineWidth: ThemeStyle.current.isHardEdged ? Theme.cardBorderWidth : 0.5))
            .overlay(
                Text(role.glyph)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Theme.brandFg))
    }
}

/// Agents role tag: small capsule with a light role-colored fill.
struct RoleTag: View {
    let role: AgentRole

    var body: some View {
        let color = Theme.roleColor(role)
        Text(role.displayName)
            .font(Theme.font.themed(9.5, .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Agents model chip: small neutral-grey capsule showing the normalized model name.
struct ModelChip: View {
    let model: String

    var body: some View {
        Text(model)
            .font(Theme.font.themed(10, .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.surfaceSecondary))
    }
}
