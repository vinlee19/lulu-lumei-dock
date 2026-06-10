import EurekaKit
import EurekaUsage
import SwiftUI

struct PopoverRootView: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var limitsService: RateLimitsService
    @State private var tab = Tab.history

    enum Tab: String, CaseIterable {
        case history = "历史"
        case usage = "用量"
        case limits = "限额"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            switch tab {
            case .history:
                HistoryView(tasks: usageService.recentHistory)
            case .usage:
                UsagePanelView(summary: usageService.summary, error: usageService.lastError)
            case .limits:
                LimitsPanelView(service: limitsService)
            }
        }
        .frame(width: 360, height: 440)
    }
}

// MARK: - 格式化助手

func formatTokens(_ count: Int) -> String {
    switch count {
    case ..<1000: return "\(count)"
    case ..<1_000_000: return String(format: "%.1fk", Double(count) / 1000)
    default: return String(format: "%.2fM", Double(count) / 1_000_000)
    }
}

func formatCost(_ usd: Double) -> String {
    usd < 0.01 && usd > 0 ? "<$0.01" : String(format: "$%.2f", usd)
}

let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.unitsStyle = .abbreviated
    return formatter
}()
