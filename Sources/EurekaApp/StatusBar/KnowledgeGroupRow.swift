import EurekaKit
import SwiftUI

/// Collapsed list row for several same-name entries installed in different places (one skill or
/// MCP server configured for several CLIs). It only summarises: name, the install sources as
/// logos and a count. Tapping expands it so the caller can list every instance with its own row
/// and per-instance actions, because the copies can differ and each one is edited on its own.
struct KnowledgeGroupRow: View {
    let name: String
    var subtitle: String?
    /// One source per instance, in list order (repeats allowed)
    let sources: [AgentSource]
    let expanded: Bool
    let onToggle: () -> Void

    private static let maxLogos = 6

    var body: some View {
        KnowledgeRow(enabled: true, onOpen: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(Theme.font.themed(9, .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                if let first = sources.first {
                    SourceLogoTile(source: first, size: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(Theme.font.monoSkillName(13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(name)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.font.themed(10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    ForEach(Array(sources.prefix(Self.maxLogos).enumerated()), id: \.offset) { _, source in
                        SourceLogoTile(source: source, size: 16)
                    }
                    if sources.count > Self.maxLogos {
                        Text("+\(sources.count - Self.maxLogos)")
                            .font(Theme.font.themed(10))
                            .foregroundStyle(.secondary)
                    }
                    CountChip(sources.count)
                }
                .help(expanded
                    ? L10n.text("Hide the individual copies", zhHans: "收起各份配置")
                    : L10n.format(
                        "Installed in %@ places; click to see and manage each one",
                        zhHans: "装在 %@ 处，点开逐份查看和管理", String(sources.count)))
            }
        } menu: {
            EmptyView()
        }
    }
}
