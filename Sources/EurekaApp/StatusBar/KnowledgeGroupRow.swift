import EurekaKit
import SwiftUI

/// Card-grid columns shared by the knowledge pages: as many 280–520pt columns as fit, so cards
/// drop to one or two columns in a narrow window instead of being squeezed into a fixed three.
enum KnowledgeGrid {
    static let columns = [GridItem(.adaptive(minimum: 280, maximum: 520), spacing: 14)]
}

/// Collapsed list row for several same-name entries installed in different places (one skill or
/// MCP server configured for several CLIs). It only summarises: name, the install sources folded
/// into a disclosure pill next to the name, and an optional read-only trailing column. Tapping
/// expands it so the caller can list every instance with its own row and per-instance actions,
/// because the copies can differ and each one is edited, toggled and deleted on its own — the
/// collapsed row must never offer an action that silently applies to all copies.
struct KnowledgeGroupRow<Trailing: View>: View {
    let name: String
    var subtitle: String?
    /// Draw the name's initials (`MonogramTile`) instead of the first source's logo, for pages
    /// whose single rows use monograms
    var monogram = false
    /// Neutral chips after the name (e.g. the project a project-scoped copy belongs to)
    var chips: [String] = []
    /// One source per instance, in list order (repeats allowed)
    let sources: [AgentSource]
    let expanded: Bool
    let onToggle: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    private static var maxLogos: Int { 5 }

    /// One logo per CLI: a global and a project copy in the same CLI would otherwise show the same
    /// logo twice
    private var uniqueSources: [AgentSource] {
        var seen = Set<AgentSource>()
        return sources.filter { seen.insert($0).inserted }
    }

    var body: some View {
        KnowledgeRow(enabled: true, onOpen: onToggle) {
            HStack(spacing: 10) {
                if monogram {
                    MonogramTile(
                        name: name,
                        source: uniqueSources.count == 1 ? uniqueSources.first : nil,
                        size: 28)
                } else if let first = sources.first {
                    SourceLogoTile(source: first, size: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    // Drop the chips before squeezing them into "…": a narrow window keeps the
                    // name and the disclosure pill, the chips reappear on the expanded rows
                    ViewThatFits(in: .horizontal) {
                        titleLine(showsChips: true)
                        titleLine(showsChips: false)
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.font.themed(10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } trailing: {
            trailing()
        } menu: {
            Button(expanded
                ? L10n.text("Collapse copies", zhHans: "收起各份配置")
                : L10n.text("Expand copies", zhHans: "展开各份配置")) { onToggle() }
        }
    }

    private func titleLine(showsChips: Bool) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(Theme.font.monoSkillName(13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(name)
            if showsChips {
                ForEach(chips, id: \.self) { TagChip($0) }
            }
            foldPill
        }
    }

    /// Disclosure pill: the install sources + copy count + chevron. It sits next to the name rather
    /// than in a leading column so the tile stays aligned with single rows.
    private var foldPill: some View {
        let hard = ThemeStyle.current.isHardEdged
        return HStack(spacing: 4) {
            ForEach(Array(uniqueSources.prefix(Self.maxLogos).enumerated()), id: \.offset) { _, source in
                SourceBadge(source: source, size: 11)
            }
            if uniqueSources.count > Self.maxLogos {
                Text("+\(uniqueSources.count - Self.maxLogos)")
                    .font(Theme.font.themedMono(9.5, .medium))
                    .foregroundStyle(.secondary)
            }
            Text(L10n.format("%@ copies", zhHans: "%@ 处", String(sources.count)))
                .font(Theme.font.themedMono(9.5, .semibold))
                .foregroundStyle(.secondary)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(Theme.font.themed(8, .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Theme.surfaceSecondary))
        .overlay(
            Capsule().strokeBorder(
                hard ? Theme.cardBorder : Theme.hairline,
                lineWidth: hard ? 1.2 : 0.7))
        .fixedSize()
        .help(expanded
            ? L10n.text("Hide the individual copies", zhHans: "收起各份配置")
            : L10n.format(
                "Installed in %@ places; click to see and manage each one",
                zhHans: "装在 %@ 处，点开逐份查看和管理", String(sources.count)))
    }
}

extension KnowledgeGroupRow where Trailing == EmptyView {
    init(
        name: String,
        subtitle: String? = nil,
        monogram: Bool = false,
        chips: [String] = [],
        sources: [AgentSource],
        expanded: Bool,
        onToggle: @escaping () -> Void
    ) {
        self.init(
            name: name, subtitle: subtitle, monogram: monogram, chips: chips,
            sources: sources, expanded: expanded, onToggle: onToggle,
            trailing: { EmptyView() })
    }
}

/// Folded row's stand-in for the switch: how many copies are enabled. Deliberately not a control —
/// copies are toggled one by one after expanding, so one click never flips an item in every CLI.
struct CopiesEnabledLabel: View {
    let enabled: Int
    let total: Int

    var body: some View {
        Text(L10n.format("%1$@/%2$@ on", zhHans: "%1$@/%2$@ 启用", String(enabled), String(total)))
            .font(Theme.font.themedMono(10, .medium))
            .foregroundStyle(enabled == total ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.goldFg))
            .lineLimit(1)
            .fixedSize()
            .help(L10n.text(
                "Expand to enable or disable each copy",
                zhHans: "展开后逐份启用或停用"))
    }
}
