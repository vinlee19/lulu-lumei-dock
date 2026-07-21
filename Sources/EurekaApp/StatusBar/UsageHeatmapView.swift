import EurekaStore
import SwiftUI

/// 活跃时段热力图卡片：周 × 24 小时网格，看什么时段用得最多。
/// 数据跟随仪表盘当前时间段/来源筛选（"今日"只有一列属预期）。
struct UsageHeatmapView: View {
    let cells: [UsageRepo.HeatmapCell]

    @State private var metric: Metric = .requests

    private enum Metric: String, CaseIterable {
        case requests = "请求数"
        case tokens = "Tokens"
    }

    /// 显示行序：周一在上（SQLite %w 语义 0=周日 … 6=周六）
    private static let displayWeekdays = [1, 2, 3, 4, 5, 6, 0]
    private static let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]

    /// (weekday*24+hour) → 格子
    private var cellMap: [Int: UsageRepo.HeatmapCell] {
        var map: [Int: UsageRepo.HeatmapCell] = [:]
        for cell in cells where (0..<7).contains(cell.weekday) && (0..<24).contains(cell.hour) {
            map[cell.weekday * 24 + cell.hour] = cell
        }
        return map
    }

    private func value(_ cell: UsageRepo.HeatmapCell?) -> Int {
        guard let cell else { return 0 }
        return metric == .requests ? cell.requests : cell.tokens
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("活跃时段")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("", selection: $metric) {
                    ForEach(Metric.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                .controlSize(.mini)
            }
            if cells.isEmpty {
                Text("该时段暂无用量")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                grid
                legend
            }
        }
        .padding(Theme.spacing.card)
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
    }

    private var grid: some View {
        let map = cellMap
        let maxValue = max(1, map.values.map { value($0) }.max() ?? 1)
        return VStack(spacing: 2) {
            // 顶行小时标签（每 6 小时一个）
            HStack(spacing: 2) {
                Text("")
                    .frame(width: 16)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 6 == 0 ? "\(hour)" : "")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(Self.displayWeekdays, id: \.self) { weekday in
                HStack(spacing: 2) {
                    Text(Self.weekdayNames[weekday])
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                    ForEach(0..<24, id: \.self) { hour in
                        let cell = map[weekday * 24 + hour]
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(value(cell), maxValue: maxValue))
                            .frame(maxWidth: .infinity)
                            .frame(height: 13)
                            .help(helpText(weekday: weekday, hour: hour, cell: cell))
                    }
                }
            }
        }
    }

    /// 单色阶梯度；sqrt 压长尾（个别高峰小时不把其余压成看不出深浅）
    private func color(_ value: Int, maxValue: Int) -> Color {
        guard value > 0 else { return Color.primary.opacity(0.04) }
        let normalized = (Double(value) / Double(maxValue)).squareRoot()
        return Theme.brand.opacity(0.15 + 0.85 * normalized)
    }

    private func helpText(weekday: Int, hour: Int, cell: UsageRepo.HeatmapCell?) -> String {
        let name = "周\(Self.weekdayNames[weekday])"
        guard let cell else { return "\(name) \(hour) 时 · 无用量" }
        return "\(name) \(hour) 时 · \(cell.requests) 次 · \(formatTokens(cell.tokens)) tokens"
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            Text("少")
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            ForEach(0..<5, id: \.self) { step in
                RoundedRectangle(cornerRadius: 2)
                    .fill(step == 0
                        ? Color.primary.opacity(0.04)
                        : Theme.brand.opacity(0.15 + 0.85 * Double(step) / 4))
                    .frame(width: 13, height: 10)
            }
            Text("多")
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
        }
    }
}
