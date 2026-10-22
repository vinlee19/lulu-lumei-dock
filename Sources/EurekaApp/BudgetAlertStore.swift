import EurekaKit
import EurekaUsage
import Foundation

/// Remembers which budget thresholds were already alerted this month (UserDefaults), and turns a
/// newly reached one into an island notice. A new month starts with a clean slate.
enum BudgetAlertStore {
    private static let monthKey = "budgetAlertMonth"
    private static let thresholdsKey = "budgetAlertThresholds"
    private static let budgetKey = "budgetAlertBudget"

    static func check(spent: Double, budget: Double, projected: Double?, now: Date = Date()) -> IslandNotice? {
        let defaults = UserDefaults.standard
        let month = MonthForecast.monthKey(now)
        // A new month or a changed budget re-arms every threshold
        let sameRun = defaults.string(forKey: monthKey) == month
            && defaults.double(forKey: budgetKey) == budget
        let alerted: Set<Double> = sameRun
            ? Set(defaults.array(forKey: thresholdsKey) as? [Double] ?? [])
            : []
        let result = BudgetAlert.evaluate(spent: spent, budget: budget, alerted: alerted)
        defaults.set(month, forKey: monthKey)
        defaults.set(budget, forKey: budgetKey)
        defaults.set(Array(result.alerted), forKey: thresholdsKey)
        guard let threshold = result.alert else { return nil }
        let over = threshold >= 1
        let projection = projected.map {
            L10n.format(" Projected by month end: %@.", zhHans: "按当前速度，月底约 %@。", formatCost($0))
        } ?? ""
        return IslandNotice(
            id: "budget-\(month)-\(Int(threshold * 100))",
            emoji: over ? "🚨" : "💸",
            headline: over
                ? L10n.text("Monthly budget used up", zhHans: "本月预算已用完")
                : L10n.format("%@ of the monthly budget used", zhHans: "本月预算已用 %@",
                              "\(Int(threshold * 100))%"),
            body: L10n.format(
                "%1$@ of %2$@ (API-equivalent).%3$@",
                zhHans: "已花费 %1$@ / 预算 %2$@（API 等价价）。%3$@",
                formatCost(spent), formatCost(budget), projection))
    }
}
