import EurekaIngest
import EurekaKit
import SwiftUI

/// "Context usage" card on the session detail page: large percentage + used/window + five-segment
/// stacked bar + category legend.
/// Shows only the summary row by default (title + percentage + stacked bar); tap to expand the
/// legend, keeping vertical space in check.
/// All styling goes through Theme tokens: the brutal theme automatically gets ink borders /
/// square corners / flat colors / monospaced digits.
struct ContextUsageCard: View {
    let breakdown: ContextBreakdown
    /// Legend expanded state (collapsed by default; reset by the caller's .id when switching
    /// sessions)
    @State private var expanded = false

    /// Usage percentage (denominator = context window)
    private var percent: Double {
        guard breakdown.windowTokens > 0 else { return 0 }
        return Double(breakdown.totalTokens) / Double(breakdown.windowTokens) * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title row: title + estimate badge + disclosure chevron (the whole row is tappable)
            HStack(spacing: 6) {
                Text(L10n.text("Context usage", zhHans: "上下文用量"))
                    .font(Theme.font.themed(12, .semibold))
                if !breakdown.totalIsReal {
                    TagChip(L10n.text("Estimated", zhHans: "估算"))
                }
                Spacer(minLength: 0)
                // A labelled 22pt toggle instead of a bare 9pt chevron: the old one was easy to
                // miss and looked like a stray glyph next to the inked card edge
                HStack(spacing: 5) {
                    Text(expanded
                        ? L10n.text("Hide breakdown", zhHans: "收起明细")
                        : L10n.text("Breakdown", zhHans: "分类明细"))
                        .font(Theme.font.themed(10.5, .medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: TileSpec.radius(22), style: .continuous)
                                .fill(Color.primary.opacity(0.05)))
                        .overlay(
                            RoundedRectangle(cornerRadius: TileSpec.radius(22), style: .continuous)
                                .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }
            .help(expanded
                ? L10n.text("Hide the breakdown", zhHans: "收起分类明细")
                : L10n.text("Show the breakdown", zhHans: "展开分类明细"))

            // Summary: large percentage + used X/Y
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.1f%%", percent))
                    .font(Theme.font.statNumber(20))
                    .foregroundStyle(Theme.percentColor(percent))
                Text(L10n.format(
                    "Used %@ / %@",
                    zhHans: "已使用 %@ / %@",
                    formatTokens(breakdown.totalTokens),
                    formatTokens(breakdown.windowTokens)))
                    .font(Theme.font.themedMono(10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            stackedBar

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(breakdown.entries) { entry in
                        legendRow(entry)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.card)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.card)
                        .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth)
                )
                .themeCardShadow()
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// Five-segment stacked bar: segment width = category tokens / window tokens; the remainder is
    /// the window's free track. brutal = square flat colors + ink border; other themes = rounded
    /// with thin borders (all dispatched via Theme tokens).
    private var stackedBar: some View {
        let hard = ThemeStyle.current.isHardEdged
        return GeometryReader { geo in
            let window = max(1, breakdown.windowTokens)
            HStack(spacing: 0) {
                ForEach(breakdown.entries) { entry in
                    let width = geo.size.width * CGFloat(entry.tokens) / CGFloat(window)
                    if width > 0.5 {
                        Rectangle()
                            .fill(Theme.contextCategoryColor(entry.category))
                            .frame(width: width)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Theme.hairline)
            .clipShape(RoundedRectangle(cornerRadius: hard ? 0 : 4))
            .overlay(
                RoundedRectangle(cornerRadius: hard ? 0 : 4)
                    .strokeBorder(hard ? Theme.ink : Theme.cardBorder,
                                  lineWidth: hard ? Theme.cardBorderWidth : 0.5)
            )
        }
        .frame(height: 10)
    }

    /// Legend row: color dot + category name + token count + percentage (monospaced digits)
    private func legendRow(_ entry: ContextBreakdown.Entry) -> some View {
        let window = max(1, breakdown.windowTokens)
        let entryPercent = Double(entry.tokens) / Double(window) * 100
        return HStack(spacing: 7) {
            Circle()
                .fill(Theme.contextCategoryColor(entry.category))
                .frame(width: 7, height: 7)
            Text(entry.category.label)
                .font(Theme.font.themed(10.5))
            Spacer(minLength: 0)
            Text(formatTokens(entry.tokens))
                .font(Theme.font.themedMono(10))
                .foregroundStyle(.secondary)
            Text(String(format: "%.1f%%", entryPercent))
                .font(Theme.font.themedMono(10))
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
