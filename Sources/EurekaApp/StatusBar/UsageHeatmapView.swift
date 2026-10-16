import EurekaKit
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

        var title: String {
            switch self {
            case .requests: return L10n.text("Requests", zhHans: "请求数")
            case .tokens: return "Tokens"
            }
        }
    }

    /// 显示行序：周一在上（SQLite %w 语义 0=周日 … 6=周六）
    private static let displayWeekdays = [1, 2, 3, 4, 5, 6, 0]
    private static func weekdayName(_ weekday: Int) -> String {
        switch weekday {
        case 0: return L10n.text("Sun", zhHans: "日")
        case 1: return L10n.text("Mon", zhHans: "一")
        case 2: return L10n.text("Tue", zhHans: "二")
        case 3: return L10n.text("Wed", zhHans: "三")
        case 4: return L10n.text("Thu", zhHans: "四")
        case 5: return L10n.text("Fri", zhHans: "五")
        default: return L10n.text("Sat", zhHans: "六")
        }
    }

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
                Text(L10n.text("Active hours", zhHans: "活跃时段"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("", selection: $metric) {
                    ForEach(Metric.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                .controlSize(.mini)
            }
            if cells.isEmpty {
                Text(L10n.text("No usage in this range", zhHans: "该时段暂无用量"))
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
                    .frame(width: 26)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 6 == 0 ? "\(hour)" : "")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(Self.displayWeekdays, id: \.self) { weekday in
                HStack(spacing: 2) {
                    Text(Self.weekdayName(weekday))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .frame(width: 26)
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
        let name = Self.weekdayName(weekday)
        let hourText = String(hour)
        guard let cell else {
            return L10n.format(
                "%1$@ %2$@:00 · no usage",
                zhHans: "周%1$@ %2$@ 时 · 无用量",
                name, hourText)
        }
        return L10n.format(
            "%1$@ %2$@:00 · %3$@ requests · %4$@ tokens",
            zhHans: "周%1$@ %2$@ 时 · %3$@ 次 · %4$@ tokens",
            name, hourText, String(cell.requests), formatTokens(cell.tokens))
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            Text(L10n.text("Less", zhHans: "少"))
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            ForEach(0..<5, id: \.self) { step in
                RoundedRectangle(cornerRadius: 2)
                    .fill(step == 0
                        ? Color.primary.opacity(0.04)
                        : Theme.brand.opacity(0.15 + 0.85 * Double(step) / 4))
                    .frame(width: 13, height: 10)
            }
            Text(L10n.text("More", zhHans: "多"))
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
        }
    }
}
