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

        /// 侧边栏图标块底色（每项一色，macOS 系统设置式）
        var tileColor: Color {
            switch self {
            case .history: return .blue
            case .sessions: return Theme.brand
            case .skills: return .orange
            case .memory: return .green
            case .plans: return Theme.gold
            case .agents: return .red
            case .usage: return .teal
            case .limits: return .indigo
            case .settings: return .gray
            }
        }

        /// 侧边栏分组（组间插入分隔线）：活动 / 知识库 / 用量 / 设置
        static let sidebarGroups: [[Tab]] = [
            [.history, .sessions],
            [.skills, .memory, .plans, .agents],
            [.usage, .limits],
            [.settings],
        ]
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

    // MARK: - 左侧边栏（macOS 系统设置式：logo 头部 + 分组彩色图标条目 + 品牌色选中胶囊）

    /// 限额徽标：三源主窗口用量的最大百分比（无数据时不显示）
    private var limitsBadge: (text: String, color: Color)? {
        guard let percent = StatusTitleComposer.maxPrimaryPercent(
            [limitsService.codex, limitsService.grok, limitsService.claude]) else { return nil }
        return ("\(Int(percent.rounded()))%", Theme.percentColor(percent))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            sidebarHeader
            Divider().padding(.vertical, 6).padding(.horizontal, 2)
            ForEach(Array(Tab.sidebarGroups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Divider().padding(.vertical, 5).padding(.horizontal, 2)
                }
                ForEach(group, id: \.self) { tab in
                    SidebarNavButton(
                        title: tab.rawValue, icon: tab.icon,
                        tileColor: tab.tileColor,
                        badge: tab == .limits ? limitsBadge?.text : nil,
                        badgeColor: (tab == .limits ? limitsBadge?.color : nil) ?? .secondary,
                        isSelected: navigation.tab == tab
                    ) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            navigation.tab = tab
                        }
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
        .frame(width: 165)
        .background(Theme.surfaceSecondary)
    }

    /// logo 头部：迷你紫金「Lu」标（与 Dock 图标同源的 LuluMark）+ 应用名
    private var sidebarHeader: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.55, green: 0.55, blue: 0.96),
                            Color(red: 0.36, green: 0.36, blue: 0.89),
                            Color(red: 0.16, green: 0.13, blue: 0.45),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 18, height: 18)
                .overlay(
                    LuluMark()
                        .stroke(Theme.gold, style: StrokeStyle(
                            lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 12, height: 7.5)
                )
            Text("lulu-lumei-dock")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
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
                usageService: usageService,
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
