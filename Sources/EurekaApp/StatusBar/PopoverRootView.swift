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
    @ObservedObject var skillMemoryService: SkillMemoryService
    @ObservedObject var plansService: PlansService
    @ObservedObject var agentConfigService: AgentConfigService
    @ObservedObject var syncService: SyncService
    @ObservedObject var cliToolsService: CLIToolsService
    @ObservedObject var auditService: AuditService
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var updateService: UpdateService
    @ObservedObject var navigation: PopoverNavigation

    enum Tab: String, CaseIterable {
        case history = "历史"
        case sessions = "会话"
        case skills = "Skills"
        case memory = "Memory"
        case plans = "Plans"
        case agents = "Agent"
        case usage = "用量"
        case limits = "限额"
        case settings = "设置"

        /// 页签图标（SF Symbol）
        var icon: String {
            switch self {
            case .history: return "clock.arrow.circlepath"
            case .sessions: return "bubble.left.and.bubble.right.fill"
            case .skills: return "wand.and.stars"
            case .memory: return "brain.fill"
            case .plans: return "list.bullet.clipboard.fill"
            case .agents: return "person.2.fill"
            case .usage: return "chart.bar.fill"
            case .limits: return "gauge.with.dots.needle.67percent"
            case .settings: return "gearshape.fill"
            }
        }

    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        // 主窗口可缩放：填满窗口；最小尺寸与 MainWindowController.minSize 对齐（避免两处打架）
        .frame(minWidth: 840, maxWidth: .infinity, minHeight: 540, maxHeight: .infinity)
        // 用量"按会话"排行 → 会话页签并选中（select 幂等，单实例前提；见 AppDelegate 只建一个 PopoverRootView）
        .onReceive(NotificationCenter.default.publisher(for: .eurekaRevealSession)) { note in
            guard let sessionId = note.object as? String else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                navigation.tab = .sessions
            }
            sessionBrowser.reveal(sessionId: sessionId)
        }
    }

    // MARK: - 左侧边栏（Claude Code 桌面版式：竖排图标+文字，品牌色选中胶囊）

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { tab in
                SidebarNavButton(
                    title: tab.rawValue, icon: tab.icon,
                    isSelected: navigation.tab == tab
                ) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        navigation.tab = tab
                    }
                }
            }
            Spacer(minLength: 0)
            Text("v\(appVersion)")
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.quaternary)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .frame(width: 150)
        .background(Theme.surfaceSecondary)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        switch navigation.tab {
        case .history:
            HistoryView(tasks: usageService.recentHistory, settings: settings)
        case .sessions:
            SessionsView(service: sessionBrowser, settings: settings)
        case .skills:
            SkillMemoryView(
                service: skillMemoryService, mode: .skills, usageService: usageService)
        case .memory:
            SkillMemoryView(
                service: skillMemoryService, mode: .memory, usageService: usageService)
        case .plans:
            PlansView(service: plansService)
        case .agents:
            AgentsView(service: agentConfigService)
        case .usage:
            UsageDashboardView(usageService: usageService, sessionBrowser: sessionBrowser)
        case .limits:
            LimitsPanelView(service: limitsService)
        case .settings:
            SettingsView(
                settings: settings, installer: installer,
                usageService: usageService, sessionBrowser: sessionBrowser,
                cliTools: cliToolsService, notificationService: notificationService,
                updateService: updateService,
                syncService: syncService, auditService: auditService)
        }
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
