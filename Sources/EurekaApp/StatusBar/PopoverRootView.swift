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
    /// The type each hub last showed. The sidebar has one "Capabilities" and one "Knowledge"
    /// entry; clicking either returns to its last type instead of always landing on the first.
    @Published var lastCapabilityTab: PopoverRootView.Tab = .skills
    @Published var lastKnowledgeTab: PopoverRootView.Tab = .memory
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
            case .skills: return L10n.text("Skills", zhHans: "技能")
            case .memory: return L10n.text("Memory", zhHans: "记忆")
            case .instructions: return L10n.text("Instructions", zhHans: "指令")
            case .plans: return L10n.text("Plans", zhHans: "计划")
            case .agents: return L10n.text("Agents", zhHans: "子代理")
            case .mcp: return "MCP"
            case .prompts: return L10n.text("Prompts", zhHans: "提示词")
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

        /// What an agent can do: skills, MCP servers, subagents. One sidebar entry, anchored on
        /// `.skills`.
        static let capabilityTabs: [Tab] = [.skills, .mcp, .agents]
        /// What an agent knows and reads into every session: memories it wrote and instructions
        /// the user wrote. One sidebar entry, anchored on `.memory`. Plans and prompts are
        /// neither: both are what sessions produced (prompts are extracted from transcripts), so
        /// they sit with sessions in the Activity group.
        static let knowledgeTabs: [Tab] = [.memory, .instructions]
        var isCapability: Bool { Self.capabilityTabs.contains(self) }
        var isKnowledge: Bool { Self.knowledgeTabs.contains(self) }
        /// The hub this tab belongs to (its type switcher's segments), or nil for plain pages.
        var hubTabs: [Tab]? {
            isCapability ? Self.capabilityTabs : (isKnowledge ? Self.knowledgeTabs : nil)
        }
        var sidebarAnchor: Tab { isCapability ? .skills : (isKnowledge ? .memory : self) }
        var sidebarTitle: String {
            switch self {
            case .skills: return L10n.text("Capabilities", zhHans: "能力")
            case .memory: return L10n.text("Knowledge", zhHans: "知识")
            default: return title
            }
        }
        var sidebarIcon: String {
            switch self {
            case .skills: return "puzzlepiece.extension.fill"
            case .memory: return "books.vertical.fill"
            default: return icon
            }
        }

        /// Sidebar groups (label + items). **Every tab must belong to a group**: `.settings` used
        /// to be in no group, hand-placed at the bottom after a `Spacer`, styled exactly like
        /// grouped items but with no separator, so it read like a stray orphan. It now belongs to
        /// the System group; only the brand footer stays at the bottom. Computed property: group
        /// names are read for the current language each time and can't go into a static let.
        static var sidebarGroups: [(label: String, tabs: [Tab])] {
            [
                (L10n.text("Activity", zhHans: "活动"), [.history, .sessions, .plans, .prompts]),
                // Two hubs (anchors `.skills` and `.memory`); each type switcher lives on its page.
                (L10n.text("Agent", zhHans: "Agent"), [.skills, .memory]),
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
            // Themed confirmations and name prompts, over everything in the window.
            ThemedDialogHost()
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
        .onChange(of: navigation.tab) { _, tab in
            if tab.isCapability { navigation.lastCapabilityTab = tab }
            if tab.isKnowledge { navigation.lastKnowledgeTab = tab }
        }
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

    /// The history badge counts the same thing as the history page header: merged sessions
    /// in the current window (last 14 days), harness background calls excluded. Zero hides it.
    private var historyBadgeText: String? {
        let merged = HistoryGrouping.mergeSessions(usageService.recentHistory)
        let count = merged.filter {
            !PromptClassifier.isHarnessUtility($0.title ?? "")
        }.count
        return count == 0 ? nil : "\(count)"
    }

    private var sidebar: some View {
        SidebarView(
            selected: navigation.tab,
            limitsBadge: limitsBadge,
            historyBadge: historyBadgeText,
            appVersion: appVersion,
            onSelect: { tab in
                // Manual navigation abandons any unconsumed cross-page reveal, confining leftovers
                // to a single reveal lifecycle
                skillMemoryService.focusPath = nil
                plansService.focusPath = nil
                let target = tab == .skills ? navigation.lastCapabilityTab
                    : (tab == .memory ? navigation.lastKnowledgeTab : tab)
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    navigation.tab = target
                }
            },
            onOpenAbout: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    navigation.tab = .settings
                    navigation.settingsSection = .about
                }
            },
            onOpenSearch: {
                withAnimation(.easeOut(duration: 0.12)) { paletteVisible = true }
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
                onOpenSession: { NotificationCenter.default.post(name: .eurekaRevealSession, object: $0) },
                settings: settings)
        case .sessions:
            SessionsView(service: sessionBrowser, settings: settings,
                         skillMemory: skillMemoryService, plans: plansService)
        case .plans:
            PlansView(service: plansService)
        case .prompts:
            PromptsView(
                service: promptsService, sessionBrowser: sessionBrowser,
                skillMemory: skillMemoryService)
        case .skills, .memory, .instructions, .agents, .mcp:
            KnowledgeHubView(
                navigation: navigation, tabs: navigation.tab.hubTabs ?? [],
                skillMemoryService: skillMemoryService, usageService: usageService,
                sessionBrowser: sessionBrowser, plansService: plansService,
                promptsService: promptsService, agentConfigService: agentConfigService,
                mcpService: mcpService)
        case .usage:
            UsageDashboardView(
                usageService: usageService, sessionBrowser: sessionBrowser, settings: settings)
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
    case ..<1_000_000_000: return String(format: "%.2fM", Double(count) / 1_000_000)
    default: return String(format: "%.2fB", Double(count) / 1_000_000_000)
    }
}

func formatCost(_ usd: Double) -> String {
    usd < 0.01 && usd > 0 ? "<$0.01" : String(format: "$%.2f", usd)
}

/// Follows the interface language (a `static let` would freeze the first language it saw, and a
/// fixed zh_CN locale printed Chinese relative times in English UI). Cached per locale: every
/// list row reads it, and building a formatter per read cost one allocation per visible row on
/// each render.
var relativeFormatter: RelativeDateTimeFormatter {
    RelativeFormatterCache.formatter(for: L10n.current.locale)
}

private enum RelativeFormatterCache {
    private static let lock = NSLock()
    private static var cached: (identifier: String, formatter: RelativeDateTimeFormatter)?

    static func formatter(for locale: Locale) -> RelativeDateTimeFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let cached, cached.identifier == locale.identifier { return cached.formatter }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        cached = (locale.identifier, formatter)
        return formatter
    }
}

/// Relative time. Anything under 5 seconds either way (including the "in 0 sec" a clock
/// step-back produces) reads "just now".
func relativeLabel(_ date: Date, relativeTo now: Date = Date()) -> String {
    if abs(now.timeIntervalSince(date)) < 5 { return L10n.text("Just now", zhHans: "刚刚") }
    return relativeFormatter.localizedString(for: date, relativeTo: now)
}
