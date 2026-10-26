import EurekaKit
import SwiftUI

/// One hub page: Capabilities (Skills / MCP / Agents) or Knowledge (Memory / Instructions),
/// chosen by `tabs`. Each has one sidebar entry; the type switcher sits in this
/// page's top bar and writes straight to `navigation.tab`, so every existing deep link
/// (`navigation.tab = .memory`, `focusPath`, ⌘K results) keeps working unchanged.
///
/// Skills renders the list + detail shell (`SkillsSplitView`) and MCP splits the same way
/// when wide. The other types still render their previous pages inside the hub until they
/// are migrated one by one.
struct KnowledgeHubView: View {
    @ObservedObject var navigation: PopoverNavigation
    /// The segments of this hub's type switcher (`Tab.capabilityTabs` or `Tab.knowledgeTabs`).
    let tabs: [PopoverRootView.Tab]

    /// Every hub page puts its search first in its own toolbar row, at this width, so the field
    /// never moves when the user switches type.
    static let searchWidth: CGFloat = 300
    @ObservedObject var skillMemoryService: SkillMemoryService
    @ObservedObject var usageService: UsageService
    @ObservedObject var sessionBrowser: SessionBrowserService
    @ObservedObject var plansService: PlansService
    @ObservedObject var promptsService: PromptsService
    @ObservedObject var agentConfigService: AgentConfigService
    @ObservedObject var mcpService: MCPService

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            content
        }
    }

    // MARK: - Top bar: type segments + (Skills only) search and actions

    /// How much the bar shows at the current width. Widths are what the full / medium
    /// rows need; below `medium` the segments are icon-only and the search field is short.
    enum BarDensity { case full, medium, compact }

    private var topBar: some View {
        GeometryReader { geo in
            // Three segments fit with titles at much narrower widths than seven did.
            let density: BarDensity = geo.size.width >= 720 ? .full
                : (geo.size.width >= 560 ? .medium : .compact)
            HStack(spacing: 10) {
                KnowledgeTypeSegments(
                    tabs: tabs,
                    selected: Binding(
                        get: { navigation.tab },
                        set: { tab in
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                navigation.tab = tab
                            }
                        }),
                    count: count(for:),
                    showsTitles: density == .full,
                    showsCounts: density != .compact)
                    .fixedSize()
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 50)
        .background(Theme.surfaceSecondary)
    }

    /// Segment counts: the full inventory, not the search-filtered view, so the numbers
    /// stay put while the user types.
    private func count(for tab: PopoverRootView.Tab) -> Int? {
        switch tab {
        case .skills: return skillMemoryService.knowledgeSnapshot().skills.count
        case .memory: return skillMemoryService.memoryTotal
        case .instructions: return skillMemoryService.instructionTotal
        case .plans: return plansService.totalCount
        case .agents: return agentConfigService.claudeAgents.count + agentConfigService.codexProfiles.count
        case .mcp: return mcpService.servers.count
        case .prompts: return promptsService.totalCount
        default: return nil
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch navigation.tab {
        case .skills:
            SkillsSplitView(
                service: skillMemoryService, usageService: usageService,
                sessionBrowser: sessionBrowser)
        case .memory:
            SkillMemoryView(
                service: skillMemoryService, mode: .memory, usageService: usageService,
                sessionBrowser: sessionBrowser)
        case .instructions:
            SkillMemoryView(
                service: skillMemoryService, mode: .instructions, usageService: usageService,
                sessionBrowser: sessionBrowser)
        case .agents:
            AgentsView(service: agentConfigService, usageService: usageService)
        case .mcp:
            MCPView(service: mcpService, usageService: usageService)
        default:
            EmptyView()
        }
    }
}

// MARK: - Type switcher

/// Segmented control over one hub's types: icon + name + count. One accent only:
/// the selected segment lifts onto `Theme.surface` (brutal: brand fill with the ink outline).
struct KnowledgeTypeSegments: View {
    let tabs: [PopoverRootView.Tab]
    @Binding var selected: PopoverRootView.Tab
    let count: (PopoverRootView.Tab) -> Int?
    var showsTitles = true
    var showsCounts = true

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                segment(tab)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .fill(Theme.surfaceTertiary))
        .overlay(
            Group {
                if let outline = Theme.controlOutline {
                    RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                        .strokeBorder(outline.color, lineWidth: outline.width)
                }
            })
    }

    private func segment(_ tab: PopoverRootView.Tab) -> some View {
        let isSelected = selected == tab
        let hard = ThemeStyle.current.isHardEdged
        return Button {
            selected = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(Theme.font.themed(11.5, .medium))
                if showsTitles {
                    Text(tab.title)
                        .font(Theme.font.themed(12, isSelected ? .medium : .regular))
                        .lineLimit(1)
                        .fixedSize()
                }
                if showsCounts, let count = count(tab) {
                    Text(formatCount(count))
                        .font(Theme.font.themedMono(10))
                        .foregroundStyle(
                            isSelected
                                ? (hard ? Theme.onBrand.opacity(0.8) : Theme.textSecondary)
                                : Theme.textTertiary)
                }
            }
            .foregroundStyle(isSelected ? (hard ? Theme.onBrand : .primary) : Theme.textSecondary)
            .padding(.horizontal, showsTitles ? 9 : 7)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.tile, style: .continuous)
                    .fill(isSelected ? (hard ? Theme.brand : Theme.surface) : .clear)
                    .shadow(
                        color: isSelected && !hard ? .black.opacity(0.10) : .clear,
                        radius: 1.5, y: 1))
            .overlay(
                Group {
                    if isSelected, let outline = Theme.controlOutline {
                        RoundedRectangle(cornerRadius: Theme.radius.tile, style: .continuous)
                            .strokeBorder(outline.color, lineWidth: outline.width)
                    }
                })
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius.tile))
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }

    private func formatCount(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : String(count)
    }
}

// MARK: - Shared pane chrome

/// A pane of the list + detail shell: surface, card border, radius and the style's shadow.
struct KnowledgePane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                    .fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous))
            .shadow(
                color: ThemeStyle.current.isHardEdged ? .clear : .black.opacity(0.05),
                radius: ThemeStyle.current.isHardEdged ? 0 : 3,
                y: ThemeStyle.current.isHardEdged ? 0 : 1.5)
            .themeCardShadow()
    }
}
