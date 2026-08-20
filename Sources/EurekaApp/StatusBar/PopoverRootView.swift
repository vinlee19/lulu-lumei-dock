import EurekaKit
import EurekaUsage
import SwiftUI

/// popover 页签导航（外部可控，首启引导直达设置页）
@MainActor
final class PopoverNavigation: ObservableObject {
    @Published var tab: PopoverRootView.Tab = .history
    /// 设置页当前子页。放这里而不是 SettingsView 的私有 @State：
    /// 侧栏底部品牌区要能直接跳「设置 → 关于」，跨页跳转本就是本类的职责。
    @Published var settingsSection: SettingsView.SettingsSection = .general
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
    @ObservedObject var mcpService: MCPService
    @ObservedObject var syncService: SyncService
    @ObservedObject var cliToolsService: CLIToolsService
    @ObservedObject var auditService: AuditService
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var updateService: UpdateService
    @ObservedObject var navigation: PopoverNavigation
    @ObservedObject var palette: CommandPaletteService

    /// ⌘K 全局搜索浮层的开关（MainMenu 经通知触发；面板本身不持有导航状态）
    @State private var paletteVisible = false

    enum Tab: String, CaseIterable {
        case history = "历史"
        case sessions = "会话"
        case skills = "Skills"
        case memory = "Memory"
        /// CLAUDE.md / AGENTS.md 这类持久指令。与 Memory 分开：那是 agent 攒的记忆，
        /// 这是用户写给 agent 的规则，混在一页会让「记忆有多少」这个数字失去意义。
        case instructions = "指令"
        case plans = "Plans"
        case agents = "Agents"
        /// MCP server 配置矩阵（只读）：同名 server 折叠一行、按源亮徽章
        case mcp = "MCP"
        case usage = "用量"
        case limits = "限额"
        case audit = "审计"
        case settings = "设置"

        /// 页签图标（SF Symbol）
        var icon: String {
            switch self {
            case .history: return "clock.arrow.circlepath"
            case .sessions: return "bubble.left.and.bubble.right.fill"
            case .skills: return "wand.and.stars"
            case .memory: return "brain.fill"
            case .instructions: return "doc.plaintext.fill"
            case .plans: return "list.bullet.clipboard.fill"
            case .agents: return "person.crop.rectangle.stack.fill"
            case .mcp: return "powerplug.fill"
            case .usage: return "chart.bar.fill"
            case .limits: return "gauge.with.dots.needle.67percent"
            case .audit: return "checkmark.shield"
            case .settings: return "gearshape.fill"
            }
        }

        /// 侧边栏图标：紫金稿统一单色中性灰（不再用彩色圆角方块）；选中项由紫色胶囊承载强调
        var tileColor: Color? { nil }

        /// 侧边栏分组（标签 + 条目）。**每个页签都要属于某一组**：
        /// 以前 `.settings` 不在任何组里、靠 `Spacer` 之后手写一行沉底，样式与组内项完全一样
        /// 却没有任何分隔，读起来是个走失的孤项。现在归入「系统」，底部只留品牌脚注。
        static let sidebarGroups: [(label: String, tabs: [Tab])] = [
            ("活动", [.history, .sessions]),
            ("知识库", [.skills, .memory, .instructions, .plans, .agents, .mcp]),
            ("安全", [.audit]),
            ("用量", [.usage, .limits]),
            ("系统", [.settings]),
        ]
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar
                Divider()
                content
            }
            if paletteVisible {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { closePalette() }
                VStack {
                    CommandPaletteView(
                        service: palette,
                        onClose: { closePalette() },
                        onRevealMessage: { id, idx in
                            sessionBrowser.revealMessage(sessionId: id, messageIdx: idx)
                        })
                    .padding(.top, 90)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        // 主窗口可缩放：填满窗口；最小尺寸与 MainWindowController.minSize 对齐（避免两处打架）
        .frame(minWidth: 840, maxWidth: .infinity, minHeight: 540, maxHeight: .infinity)
        // 主题底色（classic = 透明沿用系统窗口底；brutal = 奶油）
        .background(Theme.windowBackground)
        // 切换界面风格时整树重建：Theme.* 是静态派发 token，重建才会重新取值
        .id(settings.themeStyle)
        // 用量"按会话"排行 → 会话页签并选中（select 幂等，单实例前提；见 AppDelegate 只建一个 PopoverRootView）
        .onReceive(NotificationCenter.default.publisher(for: .eurekaRevealSession)) { note in
            guard let sessionId = note.object as? String else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                navigation.tab = .sessions
            }
            sessionBrowser.reveal(sessionId: sessionId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .eurekaRevealKnowledge)) { note in
            guard let path = note.object as? String else { return }
            let kind = note.userInfo?["kind"] as? String ?? "memory"
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                switch kind {
                case "skill": navigation.tab = .skills
                case "instruction": navigation.tab = .instructions
                default: navigation.tab = .memory
                }
            }
            skillMemoryService.focusPath = path
        }
        .onReceive(NotificationCenter.default.publisher(for: .eurekaRevealPlan)) { note in
            guard let path = note.object as? String else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { navigation.tab = .plans }
            plansService.focusPath = path
        }
        .onReceive(NotificationCenter.default.publisher(for: .eurekaToggleCommandPalette)) { note in
            // forceOpen：窗口刚被 ⌘K 唤起时只开不切（残留的 paletteVisible=true 不该反向关闭）
            let forceOpen = note.userInfo?["forceOpen"] as? Bool == true
            if paletteVisible && !forceOpen {
                closePalette()
            } else if !paletteVisible {
                withAnimation(.easeOut(duration: 0.12)) { paletteVisible = true }
            }
        }
    }

    /// 关闭面板并清空查询/结果，避免下次打开残留上次搜索
    private func closePalette() {
        withAnimation(.easeOut(duration: 0.12)) { paletteVisible = false }
        palette.reset()
    }

    // MARK: - 左侧边栏（视图在 SidebarView.swift；这里只算注入它的三个值）

    /// 限额徽标：三源主窗口用量的最大百分比（无数据时不显示）
    private var limitsBadge: (text: String, color: Color)? {
        guard let percent = StatusTitleComposer.maxPrimaryPercent(
            [limitsService.codex, limitsService.grok, limitsService.claude]) else { return nil }
        return ("\(Int(percent.rounded()))%", Theme.percentColor(percent))
    }

    private var sidebar: some View {
        SidebarView(
            selected: navigation.tab,
            limitsBadge: limitsBadge,
            // 历史徽标 = 当前窗口（近 14 天）条数；0 不显示
            historyBadge: usageService.recentHistory.isEmpty
                ? nil : "\(usageService.recentHistory.count)",
            appVersion: appVersion,
            onSelect: { tab in
                // 用户手动导航即视为放弃未消费的跨页 reveal，收敛残留窗口到一次 reveal 生命周期
                skillMemoryService.focusPath = nil
                plansService.focusPath = nil
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    navigation.tab = tab
                }
            },
            onOpenAbout: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    navigation.tab = .settings
                    navigation.settingsSection = .about
                }
            })
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        switch navigation.tab {
        case .history:
            HistoryView(
                tasks: usageService.recentHistory,
                dailyOutcomes: usageService.historyDailyOutcomes,
                tokens: usageService.historyTokens,
                runningTasks: usageService.runningTasks,
                terminals: sessionBrowser.terminals,
                onExport: { usageService.exportHistoryCSV() },
                exportMessage: usageService.exportMessage,
                settings: settings)
        case .sessions:
            SessionsView(service: sessionBrowser, settings: settings,
                         skillMemory: skillMemoryService, plans: plansService)
        case .skills:
            SkillMemoryView(
                service: skillMemoryService, mode: .skills, usageService: usageService,
                sessionBrowser: sessionBrowser)
        case .memory:
            SkillMemoryView(
                service: skillMemoryService, mode: .memory, usageService: usageService,
                sessionBrowser: sessionBrowser)
        case .instructions:
            SkillMemoryView(
                service: skillMemoryService, mode: .instructions, usageService: usageService,
                sessionBrowser: sessionBrowser)
        case .plans:
            PlansView(service: plansService)
        case .agents:
            AgentsView(service: agentConfigService, usageService: usageService)
        case .mcp:
            MCPView(service: mcpService, usageService: usageService)
        case .usage:
            UsageDashboardView(usageService: usageService, sessionBrowser: sessionBrowser)
        case .limits:
            LimitsPanelView(service: limitsService)
        case .audit:
            AuditView(
                service: auditService, installer: installer, settings: settings,
                notificationService: notificationService, skillMemory: skillMemoryService,
                mcpServers: mcpService.allEntries())
        case .settings:
            SettingsView(
                section: $navigation.settingsSection,
                settings: settings, installer: installer,
                usageService: usageService,
                cliTools: cliToolsService, notificationService: notificationService,
                updateService: updateService, syncService: syncService)
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
