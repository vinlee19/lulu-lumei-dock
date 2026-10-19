import AppKit
import EurekaIngest
import EurekaKit
import SwiftUI

/// Session detail: header + resume command bar + restore/delete actions + transcript stream +
/// transcript outline (collapsible right pane)
struct SessionDetailView: View {
    @ObservedObject var service: SessionBrowserService
    /// Dependency of the "produced in this session" section: the repo constructs this in only two
    /// places, both passing a real value; non-optional so the view refreshes once scanning finishes
    @ObservedObject var skillMemory: SkillMemoryService
    @ObservedObject var plans: PlansService
    /// Opens the lineage drill-down (provided by SessionsView -- the drill-down must replace the
    /// whole content area to get enough width)
    var onOpenLineage: ((TurnLineageView.Pane) -> Void)?

    @State private var showTOC = true
    @State private var confirmingDelete = false
    @State private var copiedCommand = false
    @State private var roleFilter: RoleFilter = .all
    @State private var searchQuery = ""
    @State private var matchIndex = 0
    /// Search hits (ordered array for prev/next navigation, Set for O(1) lookup while rendering
    /// rows). Computed in the background instead of as a computed property: a full-text scan per
    /// keystroke of a very long session after "load all" would block the main thread, and the
    /// computed version was recomputed in every visible row's contains
    @State private var matches: [Int] = []
    @State private var matchSet: Set<Int> = []
    /// Hit-recompute generation: a slow result is discarded if newer input has superseded it by the
    /// time it returns
    @State private var matchGeneration = 0
    @State private var exportNote: String?
    /// Ids of expanded trail messages (cleared on session switch so a new session with the same id
    /// doesn't expand by accident)
    @State private var expandedTrails: Set<Int> = []
    /// Whether "produced in this session" shows everything (only the first 5 by default, so dozens
    /// of artifacts don't squeeze out the transcript)
    @State private var artifactsExpanded = false

    enum RoleFilter: String, CaseIterable {
        case all = "全部"
        case user = "用户"
        case assistant = "助手"

        /// Tray label: the user side stays "User"; the other side is the agent's own product
        /// name (Claude Code, Codex, …) instead of a generic "Assistant".
        func label(for source: AgentSource?) -> String {
            switch self {
            case .all: return L10n.text("All", zhHans: "全部")
            case .user: return L10n.text("User", zhHans: "用户")
            case .assistant: return source?.displayName ?? L10n.text("Assistant", zhHans: "助手")
            }
        }
    }

    var body: some View {
        Group {
            if let session = service.selected {
                VStack(spacing: 0) {
                    header(session)
                    overviewCard(session)
                    // Context usage card: not rendered when nil (trae/antigravity/not computed
                    // yet); .id resets the collapsed state on session switch (same guard idea as
                    // artifactsExpanded)
                    if let breakdown = service.contextBreakdown {
                        ContextUsageCard(breakdown: breakdown)
                            .id(session.id)
                    }
                    searchBar
                    Divider()
                    // The outline pane uses HSplitView: the divider is draggable to resize (same
                    // interaction as the left session list), minWidth keeps timestamps intact at
                    // the narrowest, maxWidth stops it from swallowing the transcript
                    HSplitView {
                        transcriptPane(session)
                            .frame(maxWidth: .infinity)
                        if showTOC && !userMessages.isEmpty {
                            tocPane
                                .frame(minWidth: 160, idealWidth: 230, maxWidth: 560)
                        }
                    }
                }
                .confirmationDialog(
                    L10n.format(
                        "Delete session “%@”? The transcript file moves to the Trash and can be restored.",
                        zhHans: "删除会话「%@」？transcript 文件会移入废纸篓，可恢复。",
                        session.name ?? String(session.id.prefix(8))),
                    isPresented: $confirmingDelete, titleVisibility: .visible
                ) {
                    Button(L10n.text("Delete", zhHans: "删除"), role: .destructive) {
                        service.deleteSessions([session])
                    }
                    Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) {}
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.brandFg.opacity(0.4))
                    Text(L10n.text("Select a session on the left to read the conversation", zhHans: "选择左侧会话查看对话记录"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Attached to the Group: switches routed via "clear selection" also clear trail expansion
        // (same id in a new session doesn't expand)
        .onChange(of: service.selected?.id) { _, _ in
            expandedTrails = []
            artifactsExpanded = false
        }
        // Full-text hit jump: once the transcript finishes loading, scroll to the target message
        // (delayed a beat for LazyVStack layout)
        .onChange(of: service.transcriptLoading) { _, loading in
            guard !loading else { return }
            // First load / session switch / "load all" all recompute search hits against the new
            // body here
            recomputeMatches(debounce: false)
            guard let pending = service.consumePendingJump() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(name: .eurekaJumpToMessage, object: pending)
            }
        }
    }

    private var userMessages: [TranscriptMessage] {
        service.transcript.filter { $0.role == .user }
    }

    /// Message stream filtered by role (search doesn't filter, it only highlights + jumps)
    private var displayMessages: [TranscriptMessage] {
        switch roleFilter {
        case .all: return service.transcript
        case .user: return service.transcript.filter { $0.role == .user }
        case .assistant: return service.transcript.filter { $0.role == .assistant }
        }
    }

    /// Recomputes search hits: 250ms debounce (typing path) + background full-text scan +
    /// generation guard against stale results. Jumps to the first hit when done (keeps the
    /// interaction semantics of the old computed version).
    private func recomputeMatches(debounce: Bool) {
        matchGeneration += 1
        let generation = matchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + (debounce ? 0.25 : 0)) {
            guard generation == matchGeneration else { return }
            let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
            guard !query.isEmpty else {
                matches = []
                matchSet = []
                matchIndex = 0
                return
            }
            let messages = displayMessages
            DispatchQueue.global(qos: .userInitiated).async {
                let ids = messages
                    .filter { $0.text.lowercased().contains(query) }
                    .map(\.id)
                DispatchQueue.main.async {
                    guard generation == matchGeneration else { return }
                    matches = ids
                    matchSet = Set(ids)
                    matchIndex = 0
                    jumpToCurrentMatch()
                }
            }
        }
    }

    // MARK: - Header

    private func header(_ session: AgentSessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                SourceBadge(source: session.source, size: 14)
                Text(session.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .help(session.displayName)
                Spacer(minLength: 8)
                // One primary, the rest secondary, all from the shared kit so brutal gets its
                // ink capsules here instead of five system bezels
                PrimaryButton(title: L10n.text("Resume Session", zhHans: "恢复会话"), icon: "play.fill", help: L10n.text("Run the resume command in Terminal", zhHans: "在 Terminal 中执行恢复命令")) {
                    service.resumeInTerminal(session)
                }
                SecondaryButton(
                    title: L10n.text("Delete Session", zhHans: "删除会话"), icon: "trash", destructive: true,
                    help: session.source.supportsSessionDeletion
                        ? L10n.text("Moves to the Trash and can be restored", zhHans: "移入废纸篓，可恢复")
                        : L10n.format("%@ sessions live in a shared database and can't be deleted yet", zhHans: "%@ 会话存于共享数据库，暂不支持删除", "\(session.source.displayName)")
                ) {
                    confirmingDelete = true
                }
                .disabled(!session.source.supportsSessionDeletion)
                MenuButton(title: L10n.text("Export", zhHans: "导出"), icon: "square.and.arrow.up", help: L10n.text("Export the conversation", zhHans: "导出对话记录")) {
                    Button(L10n.text("Copy as Markdown", zhHans: "复制为 Markdown")) { copyMarkdown(session) }
                    Button(L10n.text("Export as .md File…", zhHans: "导出为 .md 文件…")) { exportMarkdown(session) }
                }
                if let onOpenLineage {
                    SecondaryButton(
                        title: L10n.text("Turn lineage", zhHans: "轮次血缘"), icon: "point.3.filled.connected.trianglepath.dotted",
                        help: L10n.text("See what it did each turn, and which prompt to change", zhHans: "按轮次看它做了什么、哪一轮的提示词该改")
                    ) {
                        onOpenLineage(.list)
                    }
                }
                CardActionButton(
                    icon: "list.bullet.rectangle", size: 26,
                    help: showTOC ? L10n.text("Hide the conversation outline", zhHans: "隐藏对话目录") : L10n.text("Show the conversation outline", zhHans: "显示对话目录")
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) { showTOC.toggle() }
                }
            }
            if let note = exportNote {
                Text(note)
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let started = session.startedAt {
                    metaItem("clock", started.formatted(.dateTime.month().day().hour().minute()))
                }
                if let cwd = session.cwd {
                    metaItem("folder", URL(fileURLWithPath: cwd).lastPathComponent)
                }
                // Shared-database sources (opencode / hermes) have no per-session transcript file;
                // showing the DB name would mislead
                if !session.source.usesSharedSessionDatabase {
                    metaItem("doc.text",
                             URL(fileURLWithPath: session.transcriptPath).lastPathComponent)
                }
                Spacer(minLength: 0)
            }
            terminalHistoryRow(session)
            artifactsRow(session)
            // Resume command: a labelled code strip in the kit's tertiary surface with the
            // themed mono face and a CardActionButton, instead of a bare grey pill
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.brandFg)
                Text(L10n.text("Resume command", zhHans: "恢复命令"))
                    .font(Theme.font.themed(10.5, .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(service.resumeCommand(for: session))
                    .font(Theme.font.themedMono(10.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                CardActionButton(
                    icon: copiedCommand ? "checkmark" : "doc.on.doc",
                    color: copiedCommand ? Theme.enabledGreen : .secondary,
                    size: 22, help: copiedCommand ? L10n.text("Copied", zhHans: "已复制") : L10n.text("Copy resume command", zhHans: "复制恢复命令")
                ) {
                    service.copyResumeCommand(session)
                    copiedCommand = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copiedCommand = false
                    }
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                    .fill(Theme.surfaceTertiary))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// Terminal ownership: which terminals this session has run in. Resuming in another terminal
    /// adds an entry, each with a jump button (greyed out if that terminal has exited). With no
    /// entries the row is omitted.
    @ViewBuilder
    private func terminalHistoryRow(_ session: AgentSessionInfo) -> some View {
        let history = service.terminalHistory(for: session)
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if history.count > 1 {
                    Text(L10n.format("Ran in %@ terminals", zhHans: "曾在 %@ 个终端运行", String(history.count)))
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                }
                ForEach(Array(history.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 6) {
                        TerminalBadge(
                            binding: entry.binding,
                            isRunning: TerminalActivator.isRunning(entry.binding))
                        Text(relativeFormatter.localizedString(
                            for: entry.lastSeen, relativeTo: Date()))
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                        jumpButton(entry.binding)
                    }
                }
            }
        }
    }

    /// One "produced in this session" item: a memory or a plan, merged into one list for
    /// sorting/paging
    private enum Artifact: Identifiable {
        case memory(MemoryEntry)
        case plan(PlanMaterializer.PlanEntry)

        var id: String {
            switch self {
            case .memory(let entry): return "memory:\(entry.path)"
            case .plan(let entry): return "plan:\(entry.path)"
            }
        }
    }

    /// Max artifacts shown at once; the header sits outside the ScrollView, so dozens of artifacts
    /// would squeeze out the transcript
    private static let artifactsPageSize = 6

    /// Artifacts of this session — memories whose origin / related sessions match, plans whose
    /// materialised sidecar matches — as one wrapping row of chips. Six fit on a line or two;
    /// the rest collapse into a "+N" chip. Chips, not rows: the header above the transcript is
    /// already the densest part of the page and a five-row list pushed the messages off-screen.
    @ViewBuilder
    private func artifactsRow(_ session: AgentSessionInfo) -> some View {
        let memories = skillMemory.memories(relatedTo: session.id)
        let planEntries = plans.plans(forSession: session.id)
        let items: [Artifact] = memories.map(Artifact.memory) + planEntries.map(Artifact.plan)
        if !items.isEmpty {
            let visible = artifactsExpanded ? items : Array(items.prefix(Self.artifactsPageSize))
            let hiddenCount = items.count - visible.count
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 4) {
                    Text(L10n.text("Produced by this session", zhHans: "本会话产出"))
                        .font(Theme.font.themed(10.5, .medium))
                    Text("\(items.count)")
                        .font(Theme.font.themedMono(10.5, .medium))
                }
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.top, 4)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(visible) { item in
                        artifactChip(item)
                    }
                    if hiddenCount > 0 {
                        ArtifactChip(icon: nil, title: "+\(hiddenCount)", help: L10n.text("Show everything this session produced", zhHans: "展开全部本会话产出")) {
                            artifactsExpanded = true
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func artifactChip(_ item: Artifact) -> some View {
        switch item {
        case .memory(let memory):
            let isInstruction = memory.kind == .instructions
            ArtifactChip(
                icon: isInstruction ? "doc.plaintext" : "brain", title: memory.title,
                help: (isInstruction
                    ? L10n.text("Instruction", zhHans: "指令")
                    : L10n.text("Memory", zhHans: "记忆"))
                    + " · " + L10n.text("Open on the matching page", zhHans: "在对应页面打开")
            ) {
                NotificationCenter.default.post(
                    name: .eurekaRevealKnowledge, object: memory.path,
                    userInfo: ["kind": isInstruction ? "instruction" : "memory"])
            }
        case .plan(let plan):
            ArtifactChip(
                icon: "list.bullet.clipboard", title: plan.title, help: L10n.text("Plan", zhHans: "计划") + " · "
                    + L10n.text("Open on the matching page", zhHans: "在对应页面打开")
            ) {
                NotificationCenter.default.post(name: .eurekaRevealPlan, object: plan.path)
            }
        }
    }

    /// Jump button: only brings the terminal **app** to the front (doesn't select a tab, so no
    /// Automation/Accessibility permission needed)
    private func jumpButton(_ binding: TerminalBinding) -> some View {
        let running = TerminalActivator.isRunning(binding)
        return Button {
            TerminalActivator.activate(binding)
        } label: {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 10))
        }
        .buttonStyle(.borderless)
        .disabled(!running)
        .help(running
            ? L10n.format(
                "Switch to %@ (only the app is activated; with several tabs, find the right one yourself)",
                zhHans: "切到 %@（只激活应用，多标签时需自行找到该标签）",
                binding.terminalName)
            : L10n.format("%@ is not running", zhHans: "%@ 当前未在运行", binding.terminalName))
    }

    private func metaItem(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.tertiary)
    }

    // MARK: - Overview card

    @ViewBuilder
    private func overviewCard(_ session: AgentSessionInfo) -> some View {
        let cost = service.costs[session.id]
        HStack(spacing: 24) {
            overviewStat(L10n.text("Messages", zhHans: "消息"), "\(service.transcript.count)")
            overviewStat(L10n.text("prompts", zhHans: "提问"), "\(userMessages.count)")
            if let cost {
                overviewStat("Tokens", formatTokens(cost.totalTokens))
                if let usd = cost.costUSD {
                    overviewStat(L10n.text("Cost", zhHans: "费用"), formatCost(usd), color: Theme.cost)
                }
            }
            if let span = session.duration, span >= 60 {
                overviewStat(L10n.text("Duration", zhHans: "时长"), formatDuration(span))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    /// One stat: label above a large mono number. 9.5pt tertiary labels with 11pt values were
    /// the least legible line on the page; this reads at a glance without a card around it.
    private func overviewStat(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.font.themed(10.5, .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(Theme.font.themedMono(15, .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
        }
    }

    // MARK: - Search bar

    /// Role filter + in-transcript search. Same capsule tray and SearchField as the rest of the
    /// window: the mini segmented control and bare text field used here looked like a different
    /// app next to the themed left pane.
    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: 10) {
            CapsuleTabTray {
                ForEach(RoleFilter.allCases, id: \.self) { item in
                    CapsuleTabButton(
                        title: item.label(for: service.selected?.source), fillWidth: false,
                        isSelected: roleFilter == item
                    ) {
                        roleFilter = item
                        recomputeMatches(debounce: false)
                    }
                }
            }
            SearchField(placeholder: L10n.text("Search the conversation", zhHans: "在对话中搜索"), text: $searchQuery, maxWidth: nil)
                .onChange(of: searchQuery) { _, _ in
                    recomputeMatches(debounce: true)
                }
            if !matches.isEmpty {
                Text("\(min(matchIndex + 1, matches.count)) / \(matches.count)")
                    .font(Theme.font.themedMono(11, .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                CardActionButton(icon: "chevron.up", size: 22, help: L10n.text("Previous match", zhHans: "上一处命中")) {
                    matchIndex = (matchIndex - 1 + matches.count) % matches.count
                    jumpToCurrentMatch()
                }
                CardActionButton(icon: "chevron.down", size: 22, help: L10n.text("Next match", zhHans: "下一处命中")) {
                    matchIndex = (matchIndex + 1) % matches.count
                    jumpToCurrentMatch()
                }
            } else if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(L10n.text("No matches", zhHans: "无匹配"))
                    .font(Theme.font.themed(11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func jumpToCurrentMatch() {
        guard matchIndex < matches.count else { return }
        NotificationCenter.default.post(name: .eurekaJumpToMessage, object: matches[matchIndex])
    }

    // MARK: - Export

    private func copyMarkdown(_ session: AgentSessionInfo) {
        let md = TranscriptMarkdown.render(session: session, messages: service.transcript)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        exportNote = L10n.text("Copied Markdown to the clipboard", zhHans: "已复制 Markdown 到剪贴板")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exportNote = nil }
    }

    private func exportMarkdown(_ session: AgentSessionInfo) {
        let md = TranscriptMarkdown.render(session: session, messages: service.transcript)
        let panel = NSSavePanel()
        let base = session.name.map { TranscriptMarkdown.safeFileName($0) }
            ?? String(session.id.prefix(8))
        panel.nameFieldStringValue = "\(base).md"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? Data(md.utf8).write(to: url)
            exportNote = L10n.format("Exported %@", zhHans: "已导出 %@", url.lastPathComponent)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exportNote = nil }
        }
    }

    // MARK: - Transcript stream

    private func transcriptPane(_ session: AgentSessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pane header in the same type as every other section header (Theme.font so brutal
            // gets Space Grotesk / Space Mono here too)
            HStack(spacing: 7) {
                PaneHeader(icon: "text.bubble", title: L10n.text("Conversation", zhHans: "对话记录")) {
                    CountChip(service.transcript.count)
                }
                if service.transcriptTruncated {
                    Text(L10n.format("Showing the first %@ only", zhHans: "仅显示前 %@ 条", "\(service.transcript.count)"))
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(Theme.goldFg)
                    Button(L10n.text("Load All", zhHans: "加载全部")) {
                        service.loadFullTranscript()
                    }
                    .buttonStyle(.borderless)
                    .font(Theme.font.themed(10.5, .medium))
                    .foregroundStyle(Theme.brandFg)
                    .help(L10n.text("Very long sessions are truncated by default. Click to load the rest (large files are slower).", zhHans: "超长会话默认按预算截断，点击完整加载（大文件会稍慢）"))
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if service.transcriptLoading {
                ProgressView(L10n.text("Reading the conversation…", zhHans: "正在解析对话记录…"))
                    .font(Theme.font.themed(11))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.transcript.isEmpty {
                Text(L10n.text("No messages to show", zhHans: "没有可显示的消息"))
                    .font(Theme.font.themed(11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // One block per message: avatar column + name/time header + body card
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(displayMessages) { message in
                                MessageRowView(
                                    message: message,
                                    source: session.source,
                                    isMatch: matchSet.contains(message.id),
                                    expandedTrails: $expandedTrails)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                    }
                    .onReceive(NotificationCenter.default.publisher(
                        for: .eurekaJumpToMessage)) { note in
                        if let id = note.object as? Int {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(id, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Transcript outline

    private var tocPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                PaneHeader(icon: "list.number", title: L10n.text("Outline", zhHans: "对话目录"))
                Spacer(minLength: 4)
                CountChip(L10n.format("%@ messages", zhHans: "%@ 条", "\(userMessages.count)"))
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(userMessages.enumerated()), id: \.element.id) { index, message in
                        TOCRow(index: index, message: message)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            }
        }
        .background(Theme.surfaceSecondary)
    }
}

/// Outline row: index badge + time + prompt excerpt. Width is set by dragging the outer HSplitView;
/// text wraps to fit (at most 3 lines, tail-truncated), with a light hover highlight.
private struct TOCRow: View {
    let index: Int
    let message: TranscriptMessage

    @State private var hovering = false

    var body: some View {
        Button {
            NotificationCenter.default.post(
                name: .eurekaJumpToMessage, object: message.id)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                // Capsule rather than a fixed-width circle: indexes of three digits or more (long
                // sessions reach 400+) must not truncate to "4..."
                Text("\(index + 1)")
                    .font(Theme.font.themedMono(9.5, .semibold))
                    .foregroundStyle(hovering ? Theme.onBrand : Theme.brandFg)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(
                        Capsule().fill(hovering ? Theme.brand : Theme.brandFill(0.10)))
                    .fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    if let ts = message.timestamp {
                        Text(ts, format: .dateTime.month(.twoDigits).day(.twoDigits)
                            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                            .font(Theme.font.themedMono(9.5))
                            .foregroundStyle(.secondary)
                    }
                    Text(message.text)
                        .font(Theme.font.themed(11))
                        .foregroundStyle(hovering ? .primary : .secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension Notification.Name {
    /// Outline → message stream jump (carries the message id)
    static let eurekaJumpToMessage = Notification.Name("eurekaJumpToMessage")
}

/// Clickable artifact chip: kind glyph + title on a bordered capsule, brand-tinted on hover.
/// Same metrics as the unselected SourceFilterChip so it sits next to the other chips.
private struct ArtifactChip: View {
    let icon: String?
    let title: String
    var help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(hovering ? Theme.brandFg : .secondary)
                }
                Text(title)
                    .font(Theme.font.themed(10.5, .medium))
                    .foregroundStyle(hovering ? Theme.brandFg : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(hovering ? Theme.brandFill(0.10) : Theme.surface))
            .overlay(
                Capsule().strokeBorder(
                    hovering && !ThemeStyle.current.isHardEdged ? Theme.brand.opacity(0.5) : Theme.cardBorder,
                    lineWidth: ThemeStyle.current.isHardEdged ? Theme.cardBorderWidth : 0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Message row

// MARK: - Message row

/// Streamed message row: user and assistant both left-aligned in a document-style layout, told
/// apart by a role label + subtle background tint (no more chat bubbles). The timestamp lives
/// permanently on the role-label row and the copy button appears on hover, never covering the body.
private struct MessageRowView: View {
    let message: TranscriptMessage
    /// Which agent produced this transcript; names and draws the assistant side
    let source: AgentSource
    var isMatch = false
    @Binding var expandedTrails: Set<Int>

    @State private var hovering = false
    @State private var copied = false

    /// First character of the account's full name (falls back to the short user name, then "U")
    private static let userInitial: String = {
        let name = NSFullUserName().trimmingCharacters(in: .whitespaces)
        let source = name.isEmpty ? NSUserName() : name
        return source.first.map { String($0).uppercased() } ?? "U"
    }()

    /// Width of the avatar column; secondary rows indent by it to line up with message bodies
    private static let avatarSize: CGFloat = 22
    private static let avatarGap: CGFloat = 10

    private enum Avatar {
        /// Letter avatar: the first character of the macOS account's full name on a solid brand
        /// circle (Slack / Gmail style), so the user side reads as "me" rather than a generic glyph
        case person
        case symbol(String, Color)
        case agent(AgentSource)
    }

    var body: some View {
        switch message.role {
        case .toolNote:
            HStack(spacing: 5) {
                Text(message.text)
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(Theme.brandFg.opacity(0.7))
                Spacer(minLength: 0)
            }
            .padding(.leading, Self.avatarSize + Self.avatarGap)
        case .turnTrail:
            TurnTrailRowView(
                message: message, isMatch: isMatch, expandedTrails: $expandedTrails)
                .padding(.leading, Self.avatarSize + Self.avatarGap - 8)
        case .thinking:
            ThinkingRowView(message: message, isMatch: isMatch, expanded: $expandedTrails)
                .padding(.leading, Self.avatarSize + Self.avatarGap - 8)
        case .user:
            messageBlock(
                name: L10n.text("User", zhHans: "用户"), avatar: .person, tint: Theme.brandFg,
                fill: Theme.brandFill(0.07), edge: Theme.brand.opacity(0.22)
            ) {
                MarkdownRichText(text: message.text)
            }
        case .assistant:
            messageBlock(
                name: source.displayName, avatar: .agent(source), tint: .primary,
                fill: Theme.surface, edge: Theme.hairline
            ) {
                MarkdownRichText(text: message.text)
            }
        case .error:
            messageBlock(
                name: L10n.text("Error", zhHans: "出错"), avatar: .symbol("exclamationmark.triangle.fill", Theme.failureRed),
                tint: Theme.failureRed,
                fill: Theme.failureRed.opacity(0.06), edge: Theme.failureRed.opacity(0.35)
            ) {
                Text(message.text)
                    .font(Theme.font.themed(12.5))
                    .foregroundStyle(Theme.failureRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Avatar + (header, body card)
    private func messageBlock<Body: View>(
        name: String, avatar: Avatar, tint: Color, fill: Color, edge: Color,
        @ViewBuilder body: () -> Body
    ) -> some View {
        HStack(alignment: .top, spacing: Self.avatarGap) {
            avatarView(avatar)
            VStack(alignment: .leading, spacing: 5) {
                header(name: name, tint: tint)
                body()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                            .fill(fill))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                            .strokeBorder(
                                isMatch ? Theme.gold.opacity(0.7) : edge,
                                lineWidth: isMatch ? 1.5 : 1))
            }
        }
        .onHover { hovering = $0 }
    }

    /// Avatar tile: the agent's official logo tile (shared SourceLogoTile) for the assistant
    /// side, a tinted square with a glyph for the reader and for errors — same tile language.
    @ViewBuilder
    private func avatarView(_ avatar: Avatar) -> some View {
        let size = Self.avatarSize
        switch avatar {
        case .person:
            Circle()
                .fill(Theme.brandTileGradient)
                .themeControlShadow()
                .frame(width: size, height: size)
                .overlay(
                    Text(Self.userInitial)
                        .font(Theme.font.themed(11.5, .heavy))
                        .foregroundStyle(Theme.onBrand))
                .overlay(
                    Group {
                        if let outline = Theme.controlOutline {
                            Circle().strokeBorder(outline.color, lineWidth: max(1, outline.width - 0.5))
                        }
                    })
                .padding(.top, 1)
        case .agent(let source):
            SourceLogoTile(source: source, size: size)
                .padding(.top, 1)
        case .symbol(let icon, let tint):
            RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
                .fill(TileSpec.fill(tint))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
                        .strokeBorder(
                            ThemeStyle.current.isHardEdged ? Theme.cardBorder : TileSpec.border(tint),
                            lineWidth: ThemeStyle.current.isHardEdged ? Theme.cardBorderWidth : 0.5))
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint))
                .padding(.top, 1)
        }
    }

    /// Name + timestamp, copy button on hover
    private func header(name: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(Theme.font.themed(12, .semibold))
                .foregroundStyle(tint)
            if let timestamp = message.timestamp {
                Text(timestamp, format: .dateTime.month(.twoDigits).day(.twoDigits)
                    .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(Theme.font.themedMono(10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if hovering || copied {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? L10n.text("Copied", zhHans: "已复制") : L10n.text("Copy", zhHans: "复制"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Theme.font.themed(10, .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Copy the message text", zhHans: "复制消息原文"))
                .transition(.opacity)
            }
        }
        .frame(minHeight: Self.avatarSize)
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

// Rich-text body rendering has moved to the shared MarkdownRichText.swift component (shared by
// sessions/memories/skills/plans)
