import EurekaKit
import EurekaUsage
import SwiftUI

/// Popover tab navigation (externally controllable; first-launch onboarding jumps straight to
/// Settings)
@MainActor
final class PopoverNavigation: ObservableObject {
    @Published var tab: PopoverRootView.Tab = .history
    /// Current Settings subpage. Lives here rather than as SettingsView's private @State: the
    /// sidebar's bottom brand area must jump straight to Settings → About, and cross-page jumps are
    /// this class's job anyway.
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
    @ObservedObject var promptsService: PromptsService
    @ObservedObject var agentConfigService: AgentConfigService
    @ObservedObject var mcpService: MCPService
    @ObservedObject var syncService: SyncService
    @ObservedObject var cliToolsService: CLIToolsService
    @ObservedObject var auditService: AuditService
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var updateService: UpdateService
    @ObservedObject var navigation: PopoverNavigation
    @ObservedObject var palette: CommandPaletteService

    /// Toggle for the ⌘K global search overlay (MainMenu triggers it via notification; the panel
    /// itself holds no navigation state)
    @State private var paletteVisible = false

    enum Tab: String, CaseIterable {
        case history = "历史"
        case sessions = "会话"
        case skills = "Skills"
        case memory = "Memory"
        /// Persistent instructions such as CLAUDE.md / AGENTS.md. Kept apart from Memory: that is
        /// what agents accumulate, this is the rules users write for agents; mixing them on one
        /// page would make the memory count meaningless.
        case instructions = "指令"
        case plans = "Plans"
        case agents = "Agents"
        /// MCP server config matrix (read-only): servers with the same name fold into one row, with
        /// a badge lit per source
        case mcp = "MCP"
        /// Prompt library: user prompts extracted from session transcripts, for browsing /
        /// searching / reuse in one place
        case prompts = "Prompts"
        case usage = "用量"
        case limits = "限额"
        case audit = "审计"
        case settings = "设置"

        /// Name shown in the sidebar and on tabs. rawValue keeps its original Chinese text so the
        /// existing enum identity doesn't change.
        var title: String {
            switch self {
            case .history: return L10n.text("History", zhHans: "历史")
            case .sessions: return L10n.text("Sessions", zhHans: "会话")
            case .skills: return "Skills"
            case .memory: return "Memory"
            case .instructions: return L10n.text("Instructions", zhHans: "指令")
            case .plans: return "Plans"
            case .agents: return "Agents"
            case .mcp: return "MCP"
            case .prompts: return "Prompts"
            case .usage: return L10n.text("Usage", zhHans: "用量")
            case .limits: return L10n.text("Limits", zhHans: "限额")
            case .audit: return L10n.text("Audit", zhHans: "审计")
            case .settings: return L10n.text("Settings", zhHans: "设置")
            }
        }

        /// Tab icon (SF Symbol)
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
            case .prompts: return "text.quote"
            case .usage: return "chart.bar.fill"
            case .limits: return "gauge.with.dots.needle.67percent"
            case .audit: return "checkmark.shield"
            case .settings: return "gearshape.fill"
            }
        }

        /// Sidebar icons: the purple-gold mock uses a single neutral gray (no more colored rounded
        /// squares); the selected item is emphasized by a purple capsule
        var tileColor: Color? { nil }

        /// Sidebar groups (label + items). **Every tab must belong to a group**: `.settings` used
        /// to be in no group, hand-placed at the bottom after a `Spacer`, styled exactly like
        /// grouped items but with no separator, so it read like a stray orphan. It now belongs to
        /// the System group; only the brand footer stays at the bottom. Computed property: group
        /// names are read for the current language each time and can't go into a static let.
        static var sidebarGroups: [(label: String, tabs: [Tab])] {
            [
                (L10n.text("Activity", zhHans: "活动"), [.history, .sessions]),
                (L10n.text("Knowledge", zhHans: "知识库"),
                 [.skills, .memory, .instructions, .plans, .agents, .mcp, .prompts]),
                (L10n.text("Security", zhHans: "安全"), [.audit]),
                (L10n.text("Usage", zhHans: "用量"), [.usage, .limits]),
                (L10n.text("System", zhHans: "系统"), [.settings]),
            ]
        }
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
        // The main window is resizable: fill it; the minimum size matches
        // MainWindowController.minSize (so the two don't fight)
        .frame(minWidth: 840, maxWidth: .infinity, minHeight: 540, maxHeight: .infinity)
        // Theme background (classic = transparent, keeping the system window background; brutal =
        // cream)
        .background(Theme.windowBackground)
        // Rebuild the whole tree when the interface style changes: Theme.* are statically
        // dispatched tokens, only a rebuild re-reads them
        .id("\(settings.themeStyle)|\(settings.appLanguage)")
        // Usage "by session" ranking → Sessions tab with the session selected (select is
        // idempotent, assuming a single instance; AppDelegate creates only one PopoverRootView)
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
        .onReceive(NotificationCenter.default.publisher(for: .eurekaRevealPrompt)) { note in
            guard let id = note.object as? String else { return }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                navigation.tab = .prompts
            }
            promptsService.revealPrompt(id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .eurekaToggleCommandPalette)) { note in
            // forceOpen: when ⌘K has just brought the window up, only open, never toggle (a
            // leftover paletteVisible=true must not close it)
            let forceOpen = note.userInfo?["forceOpen"] as? Bool == true
            if paletteVisible && !forceOpen {
                closePalette()
            } else if !paletteVisible {
                withAnimation(.easeOut(duration: 0.12)) { paletteVisible = true }
            }
        }
    }

    /// Close the panel and clear the query / results so the next open doesn't show the previous
    /// search
    private func closePalette() {
        withAnimation(.easeOut(duration: 0.12)) { paletteVisible = false }
        palette.reset()
    }

    // MARK: - Left sidebar (the view lives in SidebarView.swift; this only computes the three values injected into it)

    /// Rate-limit badge: the max primary-window usage percentage across the three sources (hidden
    /// when there is no data)
    private var limitsBadge: (text: String, color: Color)? {
        guard let percent = StatusTitleComposer.maxPrimaryPercent(
            [limitsService.codex, limitsService.grok, limitsService.claude, limitsService.antigravity])
        else { return nil }
        return ("\(Int(percent.rounded()))%", Theme.percentColor(percent))
    }

    private var sidebar: some View {
        SidebarView(
            selected: navigation.tab,
            limitsBadge: limitsBadge,
            // History badge = row count in the current window (last 14 days); hidden when 0
            historyBadge: usageService.recentHistory.isEmpty
                ? nil : "\(usageService.recentHistory.count)",
            appVersion: appVersion,
            onSelect: { tab in
                // Manual navigation abandons any unconsumed cross-page reveal, confining leftovers
                // to a single reveal lifecycle
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

    // MARK: - Content area

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
        case .prompts:
            PromptsView(
                service: promptsService, sessionBrowser: sessionBrowser,
                skillMemory: skillMemoryService)
        case .agents:
            AgentsView(service: agentConfigService, usageService: usageService)
        case .mcp:
            MCPView(service: mcpService, usageService: usageService)
        case .usage:
            UsageDashboardView(usageService: usageService, sessionBrowser: sessionBrowser)
        case .limits:
            LimitsPanelView(service: limitsService, settings: settings)
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

// MARK: - Formatting helpers

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
