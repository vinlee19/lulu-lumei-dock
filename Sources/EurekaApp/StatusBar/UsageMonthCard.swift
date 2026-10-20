import EurekaKit
import EurekaUsage
import SwiftUI

/// Usage → Overview, "This month": month-end projection, the monthly budget (with the
/// projection marked on the bar), and subscription payback per source. Always the whole calendar
/// month across every source, whatever the dashboard's period and filter are, because budgets and
/// plans are monthly and account-wide.
struct UsageMonthCard: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var settings: AppSettings
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("This month · all sources", zhHans: "本月 · 全部来源"))
                    .font(Theme.font.themed(12, .semibold))
                Spacer()
                SecondaryButton(
                    title: L10n.text("Budget & plans…", zhHans: "预算与套餐…"),
                    icon: "slider.horizontal.3", classic: .push
                ) { editing = true }
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    UsagePlanEditor(settings: settings, usageService: usageService)
                }
            }
            if let overview = usageService.monthOverview {
                forecastRow(overview)
                budgetRow(overview)
                paybackRows(overview)
            } else {
                Text(L10n.text("Scanning…", zhHans: "正在统计…"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    private func forecastRow(_ overview: UsageService.MonthOverview) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            stat(L10n.text("Spent so far", zhHans: "本月已花费"), formatCost(overview.monthToDate))
            stat(
                L10n.text("Projected by month end", zhHans: "月底预计"),
                overview.projected.map(formatCost) ?? "—")
                .help(L10n.text(
                    "Spent so far plus the last 7 days' daily average for the days left. API-equivalent prices.",
                    zhHans: "已花费 + 近 7 天日均 × 剩余天数，按 API 等价价计算。"))
            stat(
                L10n.text("Daily average (7 days)", zhHans: "近 7 天日均"),
                formatCost(overview.trailingSevenDays / 7))
        }
    }

    @ViewBuilder
    private func budgetRow(_ overview: UsageService.MonthOverview) -> some View {
        let budget = settings.usageMonthlyBudget
        if budget > 0 {
            let used = overview.monthToDate / budget
            let projectedShare = (overview.projected ?? 0) / budget
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.format(
                        "Budget %1$@ · %2$@ used",
                        zhHans: "预算 %1$@ · 已用 %2$@",
                        formatCost(budget), String(format: "%.0f%%", used * 100)))
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if projectedShare > 1 {
                        Text(L10n.format(
                            "On track for %@ of budget",
                            zhHans: "按当前速度月底将达预算的 %@", String(format: "%.0f%%", projectedShare * 100)))
                            .font(Theme.font.themed(10, .medium))
                            .foregroundStyle(.orange)
                    }
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(used >= 1 ? Color.red : (used >= 0.8 ? Color.orange : Theme.brand))
                            .frame(width: max(4, proxy.size.width * min(1, used)))
                        // Where the month is heading
                        Rectangle()
                            .fill(Color.primary.opacity(0.55))
                            .frame(width: 2, height: 12)
                            .offset(x: proxy.size.width * min(1, projectedShare) - 1)
                            .opacity(projectedShare > 0 ? 1 : 0)
                    }
                }
                .frame(height: 8)
            }
        } else {
            Text(L10n.text(
                "No monthly budget set. Set one to get an island alert at 80% and 100%.",
                zhHans: "未设置月预算。设置后用到 80% 和 100% 时会在灵动岛提醒。"))
                .font(Theme.font.themed(10))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func paybackRows(_ overview: UsageService.MonthOverview) -> some View {
        let plans = AgentSource.allCases.compactMap { source -> (AgentSource, Double)? in
            guard let price = settings.subscriptionPrices[source.rawValue], price > 0 else { return nil }
            return (source, price)
        }
        if plans.isEmpty {
            Text(L10n.text(
                "On a subscription? Enter its monthly price under Budget & plans to see how many times over it pays for itself.",
                zhHans: "用的是订阅套餐？在「预算与套餐」里填上月费，就能看到这个月相当于回本了几倍。"))
                .font(Theme.font.themed(10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Subscription payback", zhHans: "订阅回本"))
                    .font(Theme.font.themed(10.5, .semibold))
                    .foregroundStyle(.secondary)
                ForEach(plans, id: \.0) { source, price in
                    let spent = overview.bySource[source] ?? 0
                    let multiple = SubscriptionPayback.multiple(apiEquivalent: spent, planPrice: price) ?? 0
                    HStack {
                        Text(source.displayName)
                            .font(Theme.font.themed(11))
                        Spacer()
                        Text(L10n.format(
                            "API-equivalent %1$@ ÷ plan %2$@",
                            zhHans: "API 等价 %1$@ ÷ 套餐 %2$@", formatCost(spent), formatCost(price)))
                            .font(Theme.font.themedMono(10))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f×", multiple))
                            .font(Theme.font.themedMono(12, .semibold))
                            .foregroundStyle(multiple >= 1 ? Theme.brandFg : .orange)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(Theme.font.themedMono(15, .semibold))
                .foregroundStyle(Theme.cost)
        }
    }
}

/// Popover: monthly budget and per-source subscription prices. Sources listed are the ones with
/// spend this month plus any that already have a price.
private struct UsagePlanEditor: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var usageService: UsageService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Monthly budget", zhHans: "月预算"))
                .font(Theme.font.themed(11, .semibold))
            HStack {
                Text("$")
                TextField("0", value: $settings.usageMonthlyBudget, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                Text(L10n.text("0 = off", zhHans: "0 = 不设"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
            }
            Text(L10n.text(
                "Compared with the API-equivalent cost of every source. Alerts at 80% and 100%, once each per month.",
                zhHans: "与所有来源的 API 等价成本比较；用到 80% 和 100% 时各提醒一次（每月）。"))
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(L10n.text("Subscription price per month", zhHans: "订阅套餐月费"))
                .font(Theme.font.themed(11, .semibold))
            ForEach(sources, id: \.self) { source in
                HStack {
                    Text(source.displayName)
                        .font(Theme.font.themed(11))
                        .frame(width: 110, alignment: .leading)
                    Text("$")
                    TextField("0", value: priceBinding(source), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }
            Text(L10n.text(
                "e.g. Claude Max 100 / 200, ChatGPT Plus 20 / Pro 200. Leave 0 for pay-as-you-go.",
                zhHans: "例如 Claude Max 填 100 / 200，ChatGPT Plus 填 20、Pro 填 200；按量付费的留 0。"))
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var sources: [AgentSource] {
        let spent = Set((usageService.monthOverview?.bySource ?? [:]).filter { $0.value > 0 }.keys)
        let priced = Set(settings.subscriptionPrices.keys.compactMap(AgentSource.init(rawValue:)))
        return AgentSource.allCases.filter { spent.contains($0) || priced.contains($0) }
    }

    private func priceBinding(_ source: AgentSource) -> Binding<Double> {
        Binding(
            get: { settings.subscriptionPrices[source.rawValue] ?? 0 },
            set: { value in
                if value > 0 {
                    settings.subscriptionPrices[source.rawValue] = value
                } else {
                    settings.subscriptionPrices.removeValue(forKey: source.rawValue)
                }
            })
    }
}
