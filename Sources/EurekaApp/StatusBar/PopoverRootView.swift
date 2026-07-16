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
        case audit = "审计"
        case backup = "备份"
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
            case .audit: return "checkmark.shield.fill"
            case .backup: return "icloud.and.arrow.up.fill"
            case .settings: return "gearshape.fill"
            }
        }

        /// 页签主题色
        var accent: Color {
            switch self {
            case .history: return Theme.history
            case .sessions: return Theme.sessions
            case .skills: return Theme.skills
            case .memory: return Theme.memory
            case .plans: return Theme.plans
            case .agents: return Theme.agents
            case .usage: return Theme.usage
            case .limits: return Theme.limits
            case .audit: return Theme.audit
            case .backup: return Theme.backup
            case .settings: return Theme.settings
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 自定义彩色页签条（分段控件不支持逐段着色）
            HStack(spacing: 3) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    TabButton(
                        tab: tab, isSelected: navigation.tab == tab
                    ) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            navigation.tab = tab
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

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
            case .audit:
                AuditView(service: auditService, installer: installer)
            case .backup:
                BackupView(service: syncService, settings: settings)
            case .settings:
                SettingsView(
                    settings: settings, installer: installer,
                    usageService: usageService, sessionBrowser: sessionBrowser,
                    cliTools: cliToolsService, notificationService: notificationService)
            }
        }
        // 主窗口可缩放：填满窗口，但不小于原 popover 尺寸
        .frame(minWidth: 380, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
        // 用量"按会话"排行 → 会话页签并选中（select 幂等，单实例前提；见 AppDelegate 只建一个 PopoverRootView）
        .onReceive(NotificationCenter.default.publisher(for: .eurekaRevealSession)) { note in
            guard let sessionId = note.object as? String else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                navigation.tab = .sessions
            }
            sessionBrowser.reveal(sessionId: sessionId)
        }
    }
}

/// 彩色页签按钮：选中 = 主题色胶囊 + 白字；未选中 = 灰字、悬停微高亮
private struct TabButton: View {
    let tab: PopoverRootView.Tab
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(tab.rawValue)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .white : (hovering ? .primary : .secondary))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(tab.accent.gradient)
                        : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
