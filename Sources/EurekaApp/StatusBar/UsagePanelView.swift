import EurekaKit
import EurekaUsage
import SwiftUI

/// 用量面板：今日 / 本周，按来源分列，含估算费用与模型明细
struct UsagePanelView: View {
    let summary: UsageSummary?
    let error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                if let summary {
                    UsageSection(title: "今日", sources: summary.today)
                    UsageSection(title: "本周（周一起）", sources: summary.thisWeek)
                    Text("费用为本地估算（按公开价目），与账单可能有出入；价格表可在 ~/Library/Application Support/Eureka/pricing.json 覆盖。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView("正在扫描本地会话…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
            }
            .padding(12)
        }
    }
}

private struct UsageSection: View {
    let title: String
    let sources: [UsageSummary.SourceSummary]

    private var totalCost: Double? {
        let costs = sources.compactMap(\.costUSD)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let totalCost {
                    Text("≈ \(formatCost(totalCost))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }
            if sources.isEmpty {
                Text("暂无用量")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sources, id: \.source) { source in
                    SourceCard(summary: source)
                }
            }
        }
    }
}

private struct SourceCard: View {
    let summary: UsageSummary.SourceSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(summary.source.displayName)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if let cost = summary.costUSD {
                    Text(formatCost(cost))
                        .font(.system(size: 12, weight: .medium))
                }
                if summary.unpricedTokens > 0 {
                    Text(summary.costUSD == nil ? "未计价" : "部分未计价")
                        .font(.system(size: 9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(.orange)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    metric("请求", "\(summary.requestCount)")
                    metric("输入", formatTokens(summary.inputTokens))
                    metric("输出", formatTokens(summary.outputTokens))
                }
                GridRow {
                    metric("缓存读", formatTokens(summary.cacheReadTokens))
                    metric("缓存写", formatTokens(summary.cacheWriteTokens))
                    metric("合计", formatTokens(summary.totalTokens))
                }
            }

            if !summary.models.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(summary.models, id: \.model) { line in
                        HStack {
                            Text(line.model)
                                .font(.system(size: 10).monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatTokens(line.totalTokens))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(line.costUSD.map(formatCost) ?? "—")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
        }
    }
}
