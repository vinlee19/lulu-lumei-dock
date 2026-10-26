import AppKit
import EurekaIngest
import EurekaKit
import SwiftUI

/// Prompt library: user prompts extracted from every session, in one place to browse, search
/// and reuse.
/// List = favorite star + source badge + first-line title + project/session + time; detail =
/// full text + copy / jump back to the session.
struct PromptsView: View {
    @ObservedObject var service: PromptsService
    /// Jump back to the owning session (transcript scrolled to this prompt)
    var sessionBrowser: SessionBrowserService
    /// Prompt graduation (upgrade to a skill / instructions) goes through the knowledge service
    var skillMemory: SkillMemoryService

    /// Entry currently shown in the inline detail page (nil = list)
    @State private var detail: PromptEntry?
    @State private var deleting: PromptEntry?
    /// Source filter (nil = all)
    @State private var selectedSource: AgentSource?
    /// Expanded frequent-repeat groups (set of fingerprints)
    @State private var expandedGroups: Set<String> = []
    /// "Most effort" sort: severity descending → step count descending (surfaces the prompts
    /// most worth rewriting / templating)
    @State private var effortSort = false

    /// Offscreen-render / preview injection: open straight into one entry's detail
    /// (same convention as `PlansView(initialLayout:)`).
    init(
        service: PromptsService, sessionBrowser: SessionBrowserService,
        skillMemory: SkillMemoryService, initialDetail: PromptEntry? = nil
    ) {
        self._service = ObservedObject(wrappedValue: service)
        self.sessionBrowser = sessionBrowser
        self.skillMemory = skillMemory
        self._detail = State(initialValue: initialDetail)
    }

    /// List after search + source + favorites filtering (service already sorts by first_seen
    /// descending); the "most effort" toggle re-sorts by evaluation (unevaluated entries go last,
    /// keeping their relative order)
    private var filtered: [PromptEntry] {
        let base = service.prompts
            .filter { selectedSource == nil || $0.source == selectedSource }
        guard effortSort else { return base }
        return base.enumerated().sorted { lhs, rhs in
            let le = service.eval(of: lhs.element.id)
            let re = service.eval(of: rhs.element.id)
            let ls = le?.severity.rawValue ?? -1
            let rs = re?.severity.rawValue ?? -1
            if ls != rs { return ls > rs }
            let lc = le?.stepCount ?? 0
            let rc = re?.stepCount ?? 0
            if lc != rc { return lc > rc }
            return lhs.offset < rhs.offset  // stable sort: ties keep time order
        }.map(\.element)
    }

    var body: some View {
        Group {
            if let entry = detail, let live = service.entry(id: entry.id) {
                PromptDetailView(
                    entry: live, service: service, skillMemory: skillMemory,
                    onBack: { withAnimation(.easeOut(duration: 0.15)) { detail = nil } },
                    onDelete: { deleting = live },
                    onJumpToSession: { jumpToSession(live) })
                    .id(live.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    content
                }
            }
        }
        .onAppear {
            service.refresh()
            consumeFocus()
        }
        .onChange(of: service.focusId) { _, _ in consumeFocus() }
        .onChange(of: service.lastScanAt) { _, _ in consumeFocus() }
        .themedConfirm(
            deleting.map { L10n.format("Remove “%@” from Prompts? The source session is not affected.", zhHans: "从 Prompt 库移除「%@」？源会话不受影响。", String($0.title)) } ?? "",
            isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            confirm: L10n.text("Remove", zhHans: "移除"), destructive: true
        ) {
            if let entry = deleting {
                service.delete(entry.id)
                if detail?.id == entry.id { detail = nil }
            }
        }
    }

    // MARK: - Top bar

    private var header: some View {
        HStack(spacing: 12) {
            Text(L10n.text("Prompts", zhHans: "Prompt 库")).font(Theme.font.themed(15, .bold))
            SearchField(
                placeholder: L10n.text("Search prompts", zhHans: "搜索提问"), text: $service.searchText,
                scanning: service.scanning, resultCount: service.prompts.count)
            Spacer(minLength: 12)
            Button {
                service.favoritesOnly.toggle()
            } label: {
                Image(systemName: service.favoritesOnly ? "star.fill" : "star")
                    .font(Theme.font.themed(11, .medium))
                    .foregroundStyle(service.favoritesOnly ? Theme.gold : .secondary)
            }
            .buttonStyle(.borderless)
            .help(service.favoritesOnly ? L10n.text("Show all prompts", zhHans: "显示全部提问") : L10n.text("Favorites only", zhHans: "只看收藏"))
            Button {
                effortSort.toggle()
            } label: {
                Image(systemName: "flame")
                    .font(Theme.font.themed(11, .medium))
                    .foregroundStyle(effortSort ? Color.orange : .secondary)
            }
            .buttonStyle(.borderless)
            .help(effortSort
                ? L10n.text("Sort by time again", zhHans: "恢复时间排序")
                : L10n.text("Show the hardest prompts first (corrections, detours, many steps — the best ones to rewrite or templatize)", zhHans: "最费劲的提问排前（引来纠偏/走弯路多/步数多——最该改写或模板化）"))
            ScanStatusLabel(
                scanning: service.scanning, phase: service.scanPhase,
                lastScanAt: service.lastScanAt)
            RefreshButton(help: L10n.text("Extract again (incremental: only sessions with new messages)", zhHans: "重新提取（增量：只解析有新消息的会话）")) { service.refresh() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        // Computed once per render: sourceCounts / filtered are both O(whole library) scans;
        // previously statsCard and every source chip each computed them, and rendering started to
        // drag once the library got large
        let counts = sourceCounts
        let sources = counts.sorted { $0.value > $1.value }.map(\.key)
        let rows = filtered
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statsCard(counts: counts, sourceCount: sources.count)
                SourceFilterMenu(
                    selected: $selectedSource,
                    allLabel: L10n.text("All", zhHans: "全部"), allIcon: "text.quote",
                    totalCount: service.totalCount,
                    sources: sources,
                    count: { counts[$0] ?? 0 })
                if rows.isEmpty && service.groups.isEmpty {
                    emptyState.padding(.top, 40)
                } else if service.isSearching {
                    // Search = flat hits (including kinds folded by default, so anything can be
                    // found)
                    promptList(rows)
                } else {
                    // Three sections: favorites (user assets) → frequent repeats (template / skill
                    // candidates)
                    // → recent
                    let favorites = rows.filter(\.favorite)
                    let recent = rows.filter { !$0.favorite }
                    if !favorites.isEmpty {
                        sectionHeader("star.fill", L10n.text("Favorites", zhHans: "收藏"), favorites.count)
                        promptList(favorites)
                    }
                    if selectedSource == nil, !service.groups.isEmpty {
                        sectionHeader(
                            "repeat", L10n.text("Repeated often", zhHans: "高频重复"), service.groups.count,
                            note: L10n.text("The same thing asked again and again — the best candidates to turn into a skill or instructions", zhHans: "反复在问的同一件事 —— 升级为技能/指令的头号候选"))
                        groupsList
                    }
                    HStack(spacing: 8) {
                        sectionHeader("clock", L10n.text("Recent", zhHans: "最近"), recent.count)
                        Spacer(minLength: 8)
                        Toggle(isOn: Binding(
                            get: { service.showAll },
                            set: { service.showAll = $0 })) {
                            Text(L10n.text("Show all (including trivial text and long pastes)", zhHans: "显示全部（含琐碎/长粘贴）"))
                                .font(Theme.font.themed(10))
                                .foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.mini)
                        .help(L10n.format("Folds %@ low-reuse items by default (trivial phrases, log pastes, historical noise)", zhHans: "默认折叠 %@ 条低复用价值条目（琐碎短语/日志粘贴/历史噪音）", String(service.foldedCount)))
                    }
                    if recent.isEmpty {
                        Text(L10n.text("This source has no reusable prompts recently", zhHans: "这个来源近期没有可复用的提问"))
                            .font(Theme.font.themed(10.5))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    } else {
                        promptList(recent)
                    }
                }
            }
            .padding(22)
        }
        .background(Theme.surfaceSecondary)
    }

    /// Section header: icon + name + count
    private func sectionHeader(
        _ icon: String, _ title: String, _ count: Int, note: String? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(Theme.font.themed(10, .semibold))
                .foregroundStyle(Theme.brandFg)
            Text(title)
                .font(Theme.font.themed(11.5, .semibold))
            Text("\(count)")
                .font(Theme.font.themedMono(10))
                .foregroundStyle(.tertiary)
            if let note {
                Text("· \(note)")
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// One section's entry list (lazy: the prompt library is the first entry surface that can
    /// reach tens of thousands of items; a plain VStack would materialize every row at once when
    /// the tab opens and freeze the main thread)
    private func promptList(_ entries: [PromptEntry]) -> some View {
        KnowledgeListContainer {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    promptRow(entry)
                    if index < entries.count - 1 {
                        Divider().opacity(0.4).padding(.leading, 46)
                    }
                }
            }
        }
    }

    private func promptRow(_ entry: PromptEntry) -> some View {
        PromptRow(
            entry: entry, service: service,
            eval: service.eval(of: entry.id),
            onOpen: { open(entry) },
            onCopy: { service.copyToPasteboard(entry.id) },
            onJump: { jumpToSession(entry) },
            onRun: service.launchCommand(for: entry.id) == nil
                ? nil : { service.launchInTerminal(entry.id) })
    }

    /// Frequent-repeat groups: a group row (representative title + ×N · M projects) expands its
    /// members on click
    private var groupsList: some View {
        KnowledgeListContainer {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(service.groups.enumerated()), id: \.element.id) { index, group in
                    PromptGroupRow(
                        group: group,
                        effortCount: group.memberIds.filter {
                            (service.eval(of: $0)?.severity ?? .clean) >= .notice
                        }.count,
                        expanded: expandedGroups.contains(group.id),
                        onToggle: {
                            if expandedGroups.contains(group.id) {
                                expandedGroups.remove(group.id)
                            } else {
                                expandedGroups.insert(group.id)
                            }
                        })
                    if expandedGroups.contains(group.id) {
                        ForEach(group.memberIds, id: \.self) { memberId in
                            if let member = service.entry(id: memberId) {
                                promptRow(member)
                                    .padding(.leading, 22)
                            }
                        }
                    }
                    if index < service.groups.count - 1 {
                        Divider().opacity(0.4).padding(.leading, 46)
                    }
                }
            }
        }
    }

    private func statsCard(counts: [AgentSource: Int], sourceCount: Int) -> some View {
        let top = counts.sorted { $0.value > $1.value }.prefix(4)
        return StatOverviewCard(
            value: "\(service.totalCount)",
            unit: L10n.text("prompts", zhHans: "提问"),
            subtitle: L10n.format("%@ sources · %@ favorites", zhHans: "%@ 个来源 · 收藏 %@", String(sourceCount), String(service.favoriteCount)),
            distributionTitle: L10n.text("By source", zhHans: "来源分布"),
            segments: top.map {
                .init(label: $0.key.displayName, count: $0.value, color: Theme.brand)
            },
            showBar: false,
            trailingNote: service.foldedCount > 0
                ? L10n.format("%@ low-value items folded", zhHans: "已折叠 %@ 条低价值条目", String(service.foldedCount)) : nil)
    }

    private var sourceCounts: [AgentSource: Int] {
        var counts: [AgentSource: Int] = [:]
        for entry in service.knowledgeSnapshot() {
            counts[entry.source, default: 0] += 1
        }
        return counts
    }

    private func open(_ entry: PromptEntry) {
        withAnimation(.easeOut(duration: 0.15)) { detail = entry }
    }

    /// Jump back to the owning session (switch tab + scroll to this prompt).
    /// Same order as a command-palette transcript hit: first post the notification to switch page
    /// and select, then fill in messageIdx for positioning (pendingJump is consumed by
    /// SessionDetailView once the transcript has loaded).
    private func jumpToSession(_ entry: PromptEntry) {
        NotificationCenter.default.post(name: .eurekaRevealSession, object: entry.sessionId)
        sessionBrowser.revealMessage(sessionId: entry.sessionId, messageIdx: entry.messageIdx)
    }

    /// Cross-page jump landing: find the entry by id and open its detail (not cleared when not
    /// found — the scan may not have reached it yet)
    private func consumeFocus() {
        guard let id = service.focusId, let entry = service.entry(id: id) else { return }
        withAnimation(.easeOut(duration: 0.15)) { detail = entry }
        service.focusId = nil
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.scanning {
            VStack(spacing: 10) {
                ProgressView()
                Text(L10n.text("Extracting prompts…", zhHans: "正在提取用户提问…"))
                    .font(Theme.font.themed(12))
                    .foregroundStyle(.secondary)
                Text(L10n.text("The first extract parses every session and can take a minute or two;", zhHans: "首次提取需解析全部会话记录，可能需要一两分钟；")
                    + L10n.text(" later extracts are incremental and finish in seconds. You can switch tabs — extraction continues in the background.", zhHans: "之后为增量提取，秒级完成。可先切到其他页签，提取在后台继续。"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(
                icon: "text.quote",
                title: service.isSearching || service.favoritesOnly || selectedSource != nil
                    ? L10n.text("No matching prompts", zhHans: "没有匹配的提问") : L10n.text("No prompts extracted yet", zhHans: "还没有提取到提问"),
                hint: service.isSearching || service.favoritesOnly || selectedSource != nil
                    ? nil
                    : L10n.text("Prompts are extracted from each agent’s sessions (after the Sessions tab finishes scanning)", zhHans: "提问从各 Agent 的会话记录中自动提取（会话页签扫描完成后开始）"))
        }
    }
}

// MARK: - Shared copy for presenting evaluations

/// Rule id → short label (the primary-issue word next to a row's color dot / the signal name
/// on the detail evidence card)
func promptRuleLabel(_ rule: String) -> String {
    switch rule {
    case "explore-heavy": return L10n.text("Heavy file search", zhHans: "找文件开销大")
    case "reread": return L10n.text("Reread", zhHans: "反复回读")
    case "rework": return L10n.text("Rework", zhHans: "改后回看")
    case "retry": return L10n.text("Retry", zhHans: "反复重试")
    case "churn": return L10n.text("File churn", zhHans: "反复改同文件")
    case "clarify": return L10n.text("Clarification", zhHans: "反问澄清")
    case "corrective": return L10n.text("Correction", zhHans: "引来纠偏")
    case "reformulated": return L10n.text("Restated", zhHans: "重述打转")
    case "outcome-error": return L10n.text("Ended in error", zhHans: "报错收尾")
    default: return rule
    }
}

/// Rule id → improvement advice pointing back at the prompt (for the detail evidence card;
/// same wording basis as TurnDiagnostics' advice)
func promptRuleAdvice(_ rule: String) -> String {
    switch rule {
    case "explore-heavy": return L10n.text("Name the files or directories in the prompt to skip the search", zhHans: "提示词里直接点名文件/目录，能省掉定位开销")
    case "reread": return L10n.text("Context arrived in pieces: include the related files and constraints up front", zhHans: "上下文没一次给够：把相关文件/约束一次性给全")
    case "rework": return L10n.text("The change was made before looking closely: give the exact place to edit", zhHans: "改之前没看清：给出确切的改动位置")
    case "retry": return L10n.text("The success check was unclear: write “what counts as done” into the prompt", zhHans: "验收标准不清：把「怎样算成功」写进提示词")
    case "churn": return L10n.text("The same file was edited over and over: ask for a plan before editing", zhHans: "同一文件被反复改：先要一份改动方案再落笔")
    case "clarify": return L10n.text("The prompt was ambiguous: state the choices and constraints up front", zhHans: "提问有歧义：把选择项与约束提前写清")
    case "corrective": return L10n.text("The next prompt corrected this one — it wasn’t said clearly the first time", zhHans: "下一条提问在纠偏——这条没有一次说清")
    case "reformulated": return L10n.text("The same thing was asked again in different words: add context or a success check", zhHans: "随后换词重问了同一件事：补足上下文或验收标准")
    case "outcome-error": return L10n.text("This turn ended in an API error", zhHans: "本轮以 API 错误收尾")
    default: return ""
    }
}

/// Primary-issue word: a correction says the most, otherwise the first matched rule
func promptPrimaryRule(_ eval: PromptEval) -> String? {
    if eval.ruleIds.contains("corrective") { return "corrective" }
    return eval.ruleIds.first
}

func promptSeverityColor(_ severity: TurnDiagnostics.Severity) -> Color {
    severity == .bad ? .red : .orange
}

// MARK: - List row

/// One prompt row: favorite star + first-line title + source/project/time subtitle + hover
/// actions for copy / run in terminal / jump back.
private struct PromptRow: View {
    let entry: PromptEntry
    let service: PromptsService
    /// Evaluation result; nil = the source isn't evaluable or hasn't been rescanned (silent, no
    /// dot, never shows "clean")
    var eval: PromptEval?
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onJump: () -> Void
    /// Starts a new session with this prompt in the terminal; nil = the source doesn't support it
    /// (button hidden)
    var onRun: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                service.toggleFavorite(entry.id)
            } label: {
                Image(systemName: entry.favorite ? "star.fill" : "star")
                    .font(Theme.font.themed(11))
                    .foregroundStyle(entry.favorite ? Theme.gold : .secondary.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .help(entry.favorite ? L10n.text("Unfavorite", zhHans: "取消收藏") : L10n.text("Favorites", zhHans: "收藏"))

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(Theme.font.themed(12.5, .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    SourceBadge(source: entry.source, size: 11)
                    // Show a dot only for notice/bad (no per-entry grade; missing rows stay silent)
                    if let eval, eval.severity >= .notice {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(promptSeverityColor(eval.severity))
                                .frame(width: 6, height: 6)
                            if let rule = promptPrimaryRule(eval) {
                                Text(promptRuleLabel(rule))
                                    .font(Theme.font.themed(9.5))
                                    .foregroundStyle(promptSeverityColor(eval.severity))
                            }
                        }
                        .help(L10n.text("This prompt was hard to run (open for the evidence): ", zhHans: "这条提问执行得费劲（点开看证据）：") +
                            eval.ruleIds.map(promptRuleLabel).joined(separator: L10n.text(", ", zhHans: "、")))
                    }
                    if let project = entry.projectName {
                        Text(project).font(Theme.font.themed(10)).foregroundStyle(.secondary)
                    }
                    if let ts = entry.timestamp {
                        Text(ts, format: .dateTime.month().day().hour().minute())
                            .font(Theme.font.themedMono(9.5))
                            .foregroundStyle(.tertiary)
                    }
                    if entry.useCount > 0 {
                        Text(L10n.format("Used %@ times", zhHans: "已用 %@ 次", String(entry.useCount)))
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(Theme.brandFg.opacity(0.7))
                    }
                    ForEach(entry.tags.prefix(3), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(Theme.goldFg.opacity(0.8))
                    }
                }
            }
            Spacer(minLength: 8)
            // Always laid out and only faded in on hover: inserting the buttons on hover used to
            // take width from the title and make it re-truncate under the pointer
            HStack(spacing: 10) {
                if let onRun {
                    Button(action: onRun) {
                        Image(systemName: "play.fill").font(Theme.font.themed(10))
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.format("Start a new session in Terminal with this prompt (%@)", zhHans: "在终端以此提问启动新会话（%@）", String(entry.source.displayName)))
                }
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc").font(Theme.font.themed(10))
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Copy the prompt text", zhHans: "复制提问原文"))
                Button(action: onJump) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(Theme.font.themed(10))
                }
                .buttonStyle(.borderless)
                .help(L10n.text("View in its session", zhHans: "在所属会话中查看"))
            }
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.04) : .clear))
    }
}

// MARK: - Frequent-repeat group row

/// Group row: representative title + occurrence / project count badge + disclosure chevron.
/// Clicking anywhere on the row toggles expansion.
private struct PromptGroupRow: View {
    let group: PromptGroup
    /// Number of runs in the group that took effort (severity ≥ notice) — "asked repeatedly and
    /// hard every time" = most worth templating
    let effortCount: Int
    let expanded: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(Theme.font.themed(9, .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 11)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.representative.title)
                    .font(Theme.font.themed(12.5, .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    SourceBadge(source: group.representative.source, size: 11)
                    Text(L10n.format("Seen %@ times", zhHans: "出现 %@ 次", String(group.count)))
                        .font(Theme.font.themedMono(10))
                        .foregroundStyle(Theme.brandFg)
                    if effortCount > 0 {
                        Text(L10n.format("%@ hard runs", zhHans: "%@ 次费劲", String(effortCount)))
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(.orange)
                            .help(L10n.text("Asked repeatedly and hard to run — the best candidate to templatize or turn into a skill", zhHans: "反复在问且执行费劲——最该模板化或升级为技能的候选"))
                    }
                    if group.projectCount > 1 {
                        Text(L10n.format("Across %@ projects", zhHans: "跨 %@ 个项目", String(group.projectCount)))
                            .font(Theme.font.themed(10))
                            .foregroundStyle(Theme.goldFg)
                    }
                    if let ts = group.representative.timestamp {
                        Text(ts, format: .dateTime.month().day())
                            .font(Theme.font.themedMono(9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.04) : .clear))
    }
}

// MARK: - Detail page

/// Prompt detail: selectable full text for copying + tag editing + copy / terminal launch /
/// graduate (skill or instructions) / jump back / remove.
private struct PromptDetailView: View {
    let entry: PromptEntry
    let service: PromptsService
    let skillMemory: SkillMemoryService
    let onBack: () -> Void
    let onDelete: () -> Void
    let onJumpToSession: () -> Void

    @State private var newTag = ""
    @State private var copied = false
    /// Graduation form (nil = not open)
    @State private var graduation: GraduationMode?
    /// Brief notice for the graduation / launch result
    @State private var actionNote: String?

    enum GraduationMode: String, Identifiable {
        case skill, instruction
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    metaCard
                    MarkdownRichText(text: entry.text)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                                .fill(Theme.surface))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius.card)
                                .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
                    if let eval = service.eval(of: entry.id) {
                        evalCard(eval)
                    }
                    tagsCard
                    actionsCard
                }
                .padding(22)
            }
            .background(Theme.surfaceSecondary)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(Theme.font.themed(11, .semibold))
            }
            .buttonStyle(.borderless)
            .help(L10n.text("Back to the list", zhHans: "返回列表"))
            SourceBadge(source: entry.source, size: 14)
            Text(entry.title)
                .font(Theme.font.themed(13, .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let session = service.sessionName(for: entry) {
                Text(session)
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var metaCard: some View {
        HStack(spacing: 16) {
            if let ts = entry.timestamp {
                metaItem("clock", ts.formatted(
                    .dateTime.year().month().day().hour().minute().second()))
            }
            if let project = entry.projectName {
                metaItem("folder", project)
            }
            Text(L10n.format("%@ characters", zhHans: "%@ 字", String(entry.text.count)))
            Spacer(minLength: 0)
        }
        .font(Theme.font.themed(10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func metaItem(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(Theme.font.themed(9))
            Text(text)
        }
    }

    /// "What actually happened" evidence card: what this prompt cost the agent, and whether you
    /// were satisfied afterwards.
    /// Three-tier verdict + evidence + advice, no composite score (the evaluation system's
    /// presentation principle).
    private func evalCard(_ eval: PromptEval) -> some View {
        let capability = PromptEvalCapability.level(for: entry.source)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L10n.text("What actually happened", zhHans: "实际效果"))
                    .font(Theme.font.themed(11, .semibold))
                    .foregroundStyle(.secondary)
                if eval.severity >= .notice {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(promptSeverityColor(eval.severity))
                            .frame(width: 6, height: 6)
                        Text(eval.severity == .bad ? L10n.text("Hard", zhHans: "费劲") : L10n.text("Friction", zhHans: "有摩擦"))
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(promptSeverityColor(eval.severity))
                    }
                }
                Spacer(minLength: 4)
                if capability == .followupOnly {
                    Text(L10n.text("This source has no tool trace, only correction signals", zhHans: "该源无工具轨迹，仅纠偏信号"))
                        .font(Theme.font.themed(9))
                        .foregroundStyle(.tertiary)
                }
            }
            // Metrics row
            HStack(spacing: 12) {
                if capability != .followupOnly {
                    Text(L10n.format("%@ tool steps", zhHans: "%@ 步工具", String(eval.stepCount)))
                    if eval.errorSteps > 0 {
                        Text(L10n.format("%@ failed steps", zhHans: "%@ 步失败", String(eval.errorSteps))).foregroundStyle(.red)
                    }
                }
                if let duration = eval.duration, duration >= 5 {
                    Text(formatDuration(duration))
                }
                if eval.outcome == "error" {
                    Text(L10n.text("Ended in error", zhHans: "报错收尾")).foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
            .font(Theme.font.themedMono(10))
            .foregroundStyle(.secondary)
            // Signals and advice (one piece of evidence per line)
            let rules = eval.ruleIds.filter { $0 != "outcome-error" }
            if !rules.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rules, id: \.self) { rule in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                                .font(Theme.font.themed(9))
                                .foregroundStyle(.orange)
                                .padding(.top, 1.5)
                            Text(L10n.format("%@: %@", zhHans: "%@：%@", String(promptRuleLabel(rule)), String(promptRuleAdvice(rule))))
                                .font(Theme.font.themed(10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else if eval.severity == .clean {
                Text(L10n.text("Said clearly once, and it ran smoothly", zhHans: "一次说清，执行顺畅"))
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(.secondary)
            }
            // Static structure hints (weak prior, not part of the verdict)
            structureHints(eval.structureFlags)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                .fill(Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.card)
                .strokeBorder(
                    eval.severity == .bad
                        ? Color.red.opacity(0.35)
                        : Theme.cardBorder,
                    lineWidth: Theme.cardBorderWidth))
    }

    @ViewBuilder
    private func structureHints(_ flags: PromptStructure.Flags) -> some View {
        let hints: [String] = {
            var notes: [String] = []
            if flags.contains(.acceptance) { notes.append(L10n.text("✓ Includes a success check", zhHans: "✓ 带验收标准")) }
            if flags.contains(.filePath) { notes.append(L10n.text("✓ Names a file", zhHans: "✓ 点名了文件")) }
            if flags.contains(.deicticStart) {
                notes.append(L10n.text("△ Starts with a pointer word — it dies outside the session; add context before templatizing", zhHans: "△ 指代词开头——离开会话即失效，模板化前补上下文"))
            }
            return notes
        }()
        if !hints.isEmpty {
            Text(hints.joined(separator: " · "))
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        seconds >= 3600
            ? L10n.format("%@ hours", zhHans: "%@ 小时", String(format: "%.1f", seconds / 3600))
            : seconds >= 60
                ? L10n.format("%@ minutes", zhHans: "%@ 分钟", String(format: "%.0f", seconds / 60))
                : L10n.format("%@ seconds", zhHans: "%@ 秒", String(format: "%.0f", seconds))
    }

    private var tagsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Tags", zhHans: "标签"))
                .font(Theme.font.themed(11, .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(entry.tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Text("#\(tag)").font(Theme.font.themed(10))
                        Button {
                            service.setTags(entry.id, tags: entry.tags.filter { $0 != tag })
                        } label: {
                            Image(systemName: "xmark")
                                .font(Theme.font.themed(7, .bold))
                        }
                        .buttonStyle(.borderless)
                    }
                    .foregroundStyle(Theme.goldFg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.gold.opacity(0.12)))
                }
                TextField(L10n.text("Add a tag", zhHans: "添加标签"), text: $newTag)
                    .textFieldStyle(.plain)
                    .font(Theme.font.themed(10))
                    .frame(width: 90)
                    .onSubmit(addTag)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                .fill(Theme.surface))
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty, !entry.tags.contains(tag) else { return }
        service.setTags(entry.id, tags: entry.tags + [tag])
        newTag = ""
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PrimaryButton(
                    title: copied ? L10n.text("Copied", zhHans: "已复制") : L10n.text("Copy prompt", zhHans: "复制提问"), icon: copied ? "checkmark" : "doc.on.doc"
                ) {
                    service.copyToPasteboard(entry.id)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                if service.launchCommand(for: entry.id) != nil {
                    SecondaryButton(
                        title: L10n.text("Start a new session in Terminal", zhHans: "在终端启动新会话"), icon: "play.fill",
                        help: L10n.format("Open a new %@ session in Terminal with this prompt", zhHans: "Terminal 中以此提问开一个新的 %@ 会话", "\(entry.source.displayName)")
                            + (entry.cwd.map { L10n.format(" (%@)", zhHans: "（%@）", "\($0)") } ?? "")
                    ) {
                        service.launchInTerminal(entry.id)
                        note(L10n.text("Started a new session in Terminal", zhHans: "已在 Terminal 中启动新会话"))
                    }
                }
                SecondaryButton(
                    title: L10n.text("Turn into a skill", zhHans: "升级为技能"), icon: "graduationcap",
                    help: L10n.text("Save this prompt as a skill (SKILL.md) — the agent loads it automatically, so you don’t type it again", zhHans: "把这条提问沉淀为技能（SKILL.md）——以后 agent 自动加载，不用再重复输入")
                ) {
                    graduation = .skill
                }
                SecondaryButton(
                    title: L10n.text("Turn into instructions", zhHans: "升级为指令"), icon: "text.book.closed",
                    help: L10n.text("Save it as standing instructions, loaded every session (Claude appends to ~/.claude/CLAUDE.md; Codex appends to AGENTS.md)", zhHans: "沉淀为持久指令，之后每次会话自动加载（Claude 追加到 ~/.claude/CLAUDE.md；Codex 追加到 AGENTS.md）")
                ) {
                    graduation = .instruction
                }
                SecondaryButton(
                    title: L10n.text("View in session", zhHans: "在会话中查看"), icon: "arrow.up.left.and.arrow.down.right",
                    help: L10n.text("Switch to Sessions and scroll to this prompt", zhHans: "切到会话页签并定位到这条提问"), action: onJumpToSession)
                Spacer(minLength: 0)
                if entry.useCount > 0 {
                    Text(L10n.format("Used %@ times", zhHans: "已使用 %@ 次", String(entry.useCount))
                        + (entry.lastUsedAt.map { L10n.text(" · last ", zhHans: " · 最近 ") + $0.formatted(.dateTime.month().day()) } ?? ""))
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                }
                SecondaryButton(
                    title: L10n.text("Remove", zhHans: "移除"), icon: "trash", destructive: true,
                    help: L10n.text("Remove from Prompts (the source session is not affected)", zhHans: "从 Prompt 库移除（源会话不受影响）"), action: onDelete)
            }
            if let actionNote {
                Text(actionNote)
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $graduation) { mode in
            PromptGraduationSheet(
                mode: mode, entry: entry, skillMemory: skillMemory,
                onDone: { message in
                    graduation = nil
                    if let message { note(message) }
                })
        }
    }

    private func note(_ text: String) {
        actionNote = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { actionNote = nil }
    }
}

// MARK: - Graduation form

/// Turns a prompt into a skill or persistent instructions: pick target source + name → write to
/// disk → jump to the matching knowledge page.
private struct PromptGraduationSheet: View {
    let mode: PromptDetailView.GraduationMode
    let entry: PromptEntry
    let skillMemory: SkillMemoryService
    /// Completion callback: a non-nil message is shown on the detail page (nil = user cancelled)
    let onDone: (String?) -> Void

    @State private var name = ""
    @State private var target: AgentSource = .claude
    @State private var running = false
    @State private var errorNote: String?

    /// Instructions graduation is only offered for sources PromptInstructionDestination allows
    /// (claude appends to ~/.claude/CLAUDE.md / codex appends to AGENTS.md); skill graduation works
    /// for every source (the SKILL.md format is shared)
    private var targets: [AgentSource] {
        mode == .skill ? AgentSource.allCases : PromptInstructionDestination.supportedSources
    }

    /// In instructions mode, where the current target lands (changes with the target source)
    private var instructionHint: String {
        guard let destination = PromptInstructionDestination.destination(for: target) else {
            return L10n.text("This source has no writable instructions file.", zhHans: "该源没有可写的持久指令文件。")
        }
        return L10n.format("Append a section to %@ (backup first); %@ then loads it every session.", zhHans: "追加一节到 %@（写前自动备份），之后 %@ 每次会话自动加载。", String(destination.fileLabel), String(target.displayName))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .skill ? L10n.text("Turn into a skill", zhHans: "升级为技能") : L10n.text("Turn into instructions", zhHans: "升级为指令"))
                .font(Theme.font.themed(14, .bold))
            Text(mode == .skill
                ? L10n.text("Write this prompt as SKILL.md — the agent then loads it from the description, or you call it with /name.", zhHans: "把这条提问写成 SKILL.md —— 之后 agent 按描述自动加载，或用 /名称 显式调用。")
                : instructionHint)
                .font(Theme.font.themed(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(L10n.text("Target", zhHans: "目标"), selection: $target) {
                ForEach(targets, id: \.self) { Text($0.displayName) }
            }
            .pickerStyle(.menu)
            TextField(L10n.text("Name", zhHans: "名称"), text: $name)
                .textFieldStyle(.roundedBorder)
            if let errorNote {
                Text(errorNote)
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(L10n.text("Cancel", zhHans: "取消")) { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(running ? L10n.text("Writing…", zhHans: "写入中…") : L10n.text("Create", zhHans: "创建")) { graduate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running
                        || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            name = entry.title
            if !targets.contains(target) { target = targets[0] }
            // Default target = the prompt's own source (if it's in the supported list)
            if targets.contains(entry.source) { target = entry.source }
        }
    }

    private func graduate() {
        running = true
        errorNote = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .skill:
            skillMemory.createSkillFromPrompt(
                source: target, name: trimmed,
                description: entry.title, body: entry.text
            ) { path in
                finish(path: path, kind: "skill",
                       failure: L10n.text("Couldn’t create it: a skill with that name already exists, or the directory isn’t writable", zhHans: "创建失败：目标已存在同名技能或目录不可写"))
            }
        case .instruction:
            // The reveal kind follows the destination (both destinations are instructions in the
            // index, so it lands on the Instructions page; revealing as "memory" earlier jumped to
            // the memory page and couldn't find the target)
            let kind = PromptInstructionDestination.destination(for: target)?.knowledgeKind
                ?? "instruction"
            skillMemory.graduatePromptToInstructions(
                source: target, name: trimmed, body: entry.text
            ) { path in
                finish(path: path, kind: kind, failure: L10n.text("Couldn’t write: the instructions file can’t be read, or the directory isn’t writable", zhHans: "写入失败：指令文件读不出来或目录不可写"))
            }
        }
    }

    private func finish(path: String?, kind: String, failure: String) {
        running = false
        guard let path else {
            errorNote = failure
            return
        }
        // Jump to the matching knowledge page and focus the new file
        NotificationCenter.default.post(
            name: .eurekaRevealKnowledge, object: path, userInfo: ["kind": kind])
        onDone(kind == "skill"
            ? L10n.format("Upgraded to a %@ skill", zhHans: "已升级为 %@ 技能", String(target.displayName))
            : L10n.format("Appended to the %@ instructions file %@", zhHans: "已追加到 %@ 指令文件 %@", String(target.displayName), String(URL(fileURLWithPath: path).lastPathComponent)))
    }
}
