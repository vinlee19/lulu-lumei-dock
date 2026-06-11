import EurekaKit
import EurekaUsage
import SwiftUI

/// popover 页签导航（外部可控，首启引导直达设置页）
@MainActor
final class PopoverNavigation: ObservableObject {
    @Published var tab: PopoverRootView.Tab = .history
}

struct PopoverRootView: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var limitsService: RateLimitsService
    @ObservedObject var settings: AppSettings
    @ObservedObject var installer: InstallerService
    @ObservedObject var sessionBrowser: SessionBrowserService
    @ObservedObject var navigation: PopoverNavigation

    enum Tab: String, CaseIterable {
        case history = "历史"
        case sessions = "会话"
        case usage = "用量"
        case limits = "限额"
        case settings = "设置"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $navigation.tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            switch navigation.tab {
            case .history:
                HistoryView(tasks: usageService.recentHistory)
            case .sessions:
                SessionsView(service: sessionBrowser)
            case .usage:
                UsagePanelView(usageService: usageService)
            case .limits:
                LimitsPanelView(service: limitsService)
            case .settings:
                SettingsView(settings: settings, installer: installer)
            }
        }
        .frame(width: 380, height: 460)
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
