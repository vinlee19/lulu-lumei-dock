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

        var title: String {
            switch self {
            case .all: return L10n.text("All", zhHans: "全部")
            case .user: return L10n.text("User", zhHans: "用户")
            case .assistant: return L10n.text("Assistant", zhHans: "助手")
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
                Button {
                    service.resumeInTerminal(session)
                } label: {
                    Label(L10n.text("Resume Session", zhHans: "恢复会话"), systemImage: "play.fill")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
                .help(L10n.text("Run the resume command in Terminal", zhHans: "在 Terminal 中执行恢复命令"))
                Button {
                    confirmingDelete = true
                } label: {
                    Label(L10n.text("Delete Session", zhHans: "删除会话"), systemImage: "trash")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!session.source.supportsSessionDeletion)
                .help(session.source.supportsSessionDeletion
                    ? L10n.text("Moves to the Trash and can be restored", zhHans: "移入废纸篓，可恢复")
                    : L10n.format(
                        "%@ sessions live in a shared database and can't be deleted yet",
                        zhHans: "%@ 会话存于共享数据库，暂不支持删除",
                        session.source.displayName))
                Menu {
                    Button(L10n.text("Copy as Markdown", zhHans: "复制为 Markdown")) { copyMarkdown(session) }
                    Button(L10n.text("Export as .md File…", zhHans: "导出为 .md 文件…")) { exportMarkdown(session) }
                } label: {
                    Label(L10n.text("Export", zhHans: "导出"), systemImage: "square.and.arrow.up")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L10n.text("Export the conversation", zhHans: "导出对话记录"))
                if let onOpenLineage {
                    Button {
                        onOpenLineage(.list)
                    } label: {
                        Label(L10n.text("Turn lineage", zhHans: "轮次血缘"), systemImage:
                            "point.3.filled.connected.trianglepath.dotted")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help(L10n.text("See what it did each turn, and which prompt to change", zhHans: "按轮次看它做了什么、哪一轮的提示词该改"))
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showTOC.toggle() }
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help(showTOC
                    ? L10n.text("Hide the conversation outline", zhHans: "隐藏对话目录")
                    : L10n.text("Show the conversation outline", zhHans: "显示对话目录"))
            }
            if let note = exportNote {
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let started = session.startedAt {
                    metaItem("clock", started.formatted(.dateTime.year().month().day().hour().minute().second()))
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
            // resume command bar
            HStack(spacing: 6) {
                Text(service.resumeCommand(for: session))
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button {
                    service.copyResumeCommand(session)
                    copiedCommand = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copiedCommand = false
                    }
                } label: {
                    Image(systemName: copiedCommand ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Copy resume command", zhHans: "复制恢复命令"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
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
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                ForEach(Array(history.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 6) {
                        TerminalBadge(
                            binding: entry.binding,
                            isRunning: TerminalActivator.isRunning(entry.binding))
                        Text(relativeFormatter.localizedString(
                            for: entry.lastSeen, relativeTo: Date()))
                            .font(.system(size: 9.5))
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
    private static let artifactsPageSize = 5

    /// Produced in this session: memories (originSessionId/relatedSessions match) + plans
    /// (materialized sidecar sessionId match)
    @ViewBuilder
    private func artifactsRow(_ session: AgentSessionInfo) -> some View {
        let memories = skillMemory.memories(relatedTo: session.id)
        let planEntries = plans.plans(forSession: session.id)
        let items: [Artifact] = memories.map(Artifact.memory) + planEntries.map(Artifact.plan)
        if !items.isEmpty {
            let visible = artifactsExpanded ? items : Array(items.prefix(Self.artifactsPageSize))
            let hiddenCount = items.count - visible.count
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("Produced by this session", zhHans: "本会话产出"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                ForEach(visible) { item in
                    artifactLine(item)
                }
                if hiddenCount > 0 {
                    Text(L10n.format("%@ more", zhHans: "还有 %@ 条", String(hiddenCount)))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                        .onTapGesture { artifactsExpanded = true }
                        .help(L10n.text("Show everything this session produced", zhHans: "展开全部本会话产出"))
                }
            }
        }
    }

    @ViewBuilder
    private func artifactLine(_ item: Artifact) -> some View {
        switch item {
        case .memory(let memory):
            let isInstruction = memory.kind == .instructions
            artifactLine(
                icon: "brain", title: memory.title,
                note: isInstruction ? L10n.text("Instruction", zhHans: "指令") : L10n.text("Memory", zhHans: "记忆")
            ) {
                NotificationCenter.default.post(
                    name: .eurekaRevealKnowledge, object: memory.path,
                    userInfo: ["kind": isInstruction ? "instruction" : "memory"])
            }
        case .plan(let plan):
            artifactLine(icon: "list.bullet.clipboard", title: plan.title, note: L10n.text("Plan", zhHans: "计划")) {
                NotificationCenter.default.post(name: .eurekaRevealPlan, object: plan.path)
            }
        }
    }

    private func artifactLine(
        icon: String, title: String, note: String, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Theme.brandFg)
            Text(title)
                .font(Theme.font.themed(11))
                .lineLimit(1)
            Text(note)
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help(L10n.text("Open on the matching page", zhHans: "在对应页面打开"))
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
        HStack(spacing: 16) {
            overviewStat(L10n.text("Messages", zhHans: "消息"), "\(service.transcript.count)")
            overviewStat(L10n.text("Prompts", zhHans: "提问"), "\(userMessages.count)")
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
        .padding(.bottom, 6)
    }

    private func overviewStat(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    // MARK: - Search bar

    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $roleFilter) {
                ForEach(RoleFilter.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .controlSize(.mini)
            .onChange(of: roleFilter) { _, _ in
                recomputeMatches(debounce: false)
            }

            Image(systemName: "magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            TextField(L10n.text("Search the conversation", zhHans: "在对话中搜索"), text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onChange(of: searchQuery) { _, _ in
                    recomputeMatches(debounce: true)
                }
            if !matches.isEmpty {
                Text("\(min(matchIndex + 1, matches.count))/\(matches.count)")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    matchIndex = (matchIndex - 1 + matches.count) % matches.count
                    jumpToCurrentMatch()
                } label: { Image(systemName: "chevron.up").font(.system(size: 9)) }
                .buttonStyle(.borderless)
                Button {
                    matchIndex = (matchIndex + 1) % matches.count
                    jumpToCurrentMatch()
                } label: { Image(systemName: "chevron.down").font(.system(size: 9)) }
                .buttonStyle(.borderless)
            } else if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(L10n.text("No matches", zhHans: "无匹配"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 7)
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
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(L10n.text("Conversation", zhHans: "对话记录"))
                    .font(.system(size: 11, weight: .semibold))
                Text("\(service.transcript.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.brand.opacity(0.12)))
                    .foregroundStyle(Theme.brandFg)
                if service.transcriptTruncated {
                    Text(L10n.format("Showing the first %@ only", zhHans: "仅显示前 %@ 条", String(service.transcript.count)))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                    Button(L10n.text("Load All", zhHans: "加载全部")) {
                        service.loadFullTranscript()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.brandFg)
                    .help(L10n.text("Very long sessions are truncated by default. Click to load the rest (large files are slower).", zhHans: "超长会话默认按预算截断，点击完整加载（大文件会稍慢）"))
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()

            if service.transcriptLoading {
                ProgressView(L10n.text("Reading the conversation…", zhHans: "正在解析对话记录…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.transcript.isEmpty {
                Text(L10n.text("No messages to show", zhHans: "没有可显示的消息"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Document-style layout: everything left-aligned, role labels tell message
                        // origins apart
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(displayMessages) { message in
                                MessageRowView(
                                    message: message,
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
            HStack(spacing: 5) {
                Image(systemName: "list.number")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(L10n.text("Outline", zhHans: "对话目录"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                Text(L10n.format("%@ messages", zhHans: "%@ 条", String(userMessages.count)))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
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
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(hovering ? Theme.onBrand : Theme.brandFg)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(
                        Capsule().fill(hovering ? Theme.brand : Theme.brand.opacity(0.1)))
                    .fixedSize()
                VStack(alignment: .leading, spacing: 1.5) {
                    if let ts = message.timestamp {
                        Text(ts, format: .dateTime.month(.twoDigits).day(.twoDigits)
                            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                            .font(.system(size: 8.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(message.text)
                        .font(.system(size: 10.5))
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

// MARK: - Message row

/// Streamed message row: user and assistant both left-aligned in a document-style layout, told
/// apart by a role label + subtle background tint (no more chat bubbles). The timestamp lives
/// permanently on the role-label row and the copy button appears on hover, never covering the body.
private struct MessageRowView: View {
    let message: TranscriptMessage
    var isMatch = false
    @Binding var expandedTrails: Set<Int>

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        switch message.role {
        case .toolNote:
            HStack(spacing: 5) {
                Text(message.text)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.brandFg.opacity(0.65))
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
        case .turnTrail:
            TurnTrailRowView(
                message: message, isMatch: isMatch, expandedTrails: $expandedTrails)
        case .thinking:
            ThinkingRowView(message: message, isMatch: isMatch, expanded: $expandedTrails)
        case .user:
            VStack(alignment: .leading, spacing: 4) {
                roleHeader(label: L10n.text("User", zhHans: "用户"), icon: "person.fill", color: Theme.brandFg)
                MarkdownRichText(text: message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                            .fill(Theme.brandFill(0.05)))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                            .strokeBorder(
                                isMatch ? Theme.gold.opacity(0.6) : .clear,
                                lineWidth: 1.5))
            }
            .onHover { hovering = $0 }
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                roleHeader(label: L10n.text("Assistant", zhHans: "助手"), icon: "sparkles", color: .secondary)
                MarkdownRichText(text: message.text)
                    .padding(.horizontal, 2)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                            .fill(isMatch ? Theme.gold.opacity(0.10) : .clear)
                            .padding(-4))
            }
            .onHover { hovering = $0 }
        case .error:
            VStack(alignment: .leading, spacing: 4) {
                roleHeader(label: L10n.text("Error", zhHans: "错误"), icon: "exclamationmark.triangle.fill", color: .red)
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.red.opacity(0.8))
                        .frame(width: 3)
                    Text(message.text)
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                    .fill(Color.red.opacity(0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                        .strokeBorder(isMatch ? Theme.gold.opacity(0.6) : .clear, lineWidth: 1.5))
            }
            .onHover { hovering = $0 }
        }
    }

    /// Role-label row: icon + role name + timestamp (always shown, faint) + copy button (appears on
    /// hover)
    @ViewBuilder
    private func roleHeader(label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(color)
            Text(label)
                .font(Theme.font.themed(10, .medium))
                .foregroundStyle(color)
            if let timestamp = message.timestamp {
                Text(timestamp, format: .dateTime.month(.twoDigits).day(.twoDigits)
                    .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(Theme.font.themedMono(9))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if hovering || copied {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Copy the message text", zhHans: "复制消息原文"))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 2)
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

// Rich-text body rendering has moved to the shared MarkdownRichText.swift component (shared by
// sessions/memories/skills/plans)
