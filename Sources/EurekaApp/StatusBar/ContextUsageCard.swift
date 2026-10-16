import EurekaIngest
import SwiftUI

/// 会话详情页「上下文用量」卡片：大字号百分比 + 已用/窗口 + 五段堆叠条 + 分类图例。
/// 默认只显示摘要行（标题 + 百分比 + 堆叠条），点开展开图例，控制纵向占位。
/// 全部样式走 Theme token：brutal 主题自动得墨边/直角/平色/等宽数字。
struct ContextUsageCard: View {
    let breakdown: ContextBreakdown
    /// 图例展开态（默认折叠；切会话由调用方 .id 重置）
    @State private var expanded = false

    /// 占用百分比（分母 = 上下文窗口）
    private var percent: Double {
        guard breakdown.windowTokens > 0 else { return 0 }
        return Double(breakdown.totalTokens) / Double(breakdown.windowTokens) * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题行：标题 + 估算徽章 + 展开箭头（整行可点）
            HStack(spacing: 6) {
                Text("上下文用量")
                    .font(Theme.font.themed(12, .semibold))
                if !breakdown.totalIsReal {
                    TagChip("估算")
                }
                Spacer(minLength: 0)
                // A labelled 22pt toggle instead of a bare 9pt chevron: the old one was easy to
                // miss and looked like a stray glyph next to the inked card edge
                HStack(spacing: 5) {
                    Text(expanded ? "收起明细" : "分类明细")
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
            .help(expanded ? "收起分类明细" : "展开分类明细")

            // 摘要：大字号百分比 + 已使用 X/Y
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.1f%%", percent))
                    .font(Theme.font.statNumber(20))
                    .foregroundStyle(Theme.percentColor(percent))
                Text("已使用 \(formatTokens(breakdown.totalTokens)) / \(formatTokens(breakdown.windowTokens))")
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

    /// 五段堆叠条：段宽 = 类目 tokens / 窗口 tokens；剩余为窗口余量轨道。
    /// brutal = 直角平色 + 墨边；其余主题 = 圆角细边（全走 Theme token 分派）。
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

    /// 图例行：色点 + 类目名 + token 数 + 百分比（等宽数字）
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
