import AppKit
import EurekaIngest
import EurekaKit
import SwiftUI

/// 会话详情：头部信息 + resume 命令条 + 恢复/删除动作 + 对话记录流 + 对话目录（可折叠右栏）
struct SessionDetailView: View {
    @ObservedObject var service: SessionBrowserService
    /// 「本会话产出」区依赖：全仓只有两处构造点且都传实值，非 optional 让扫描完成后能正常刷新
    @ObservedObject var skillMemory: SkillMemoryService
    @ObservedObject var plans: PlansService
    /// 打开血缘下钻（由 SessionsView 提供 —— 下钻要替换整个内容区才有足够宽度）
    var onOpenLineage: ((TurnLineageView.Pane) -> Void)?

    @State private var showTOC = true
    @State private var confirmingDelete = false
    @State private var copiedCommand = false
    @State private var roleFilter: RoleFilter = .all
    @State private var searchQuery = ""
    @State private var matchIndex = 0
    /// 搜索命中（顺序数组供上下条导航，Set 供行渲染 O(1) 查询）。
    /// 在后台算而不是 computed property：加载全部后的超长会话逐键全文扫描会卡主线程，
    /// 且 computed 版本在每个可见行的 contains 里被反复重算过
    @State private var matches: [Int] = []
    @State private var matchSet: Set<Int> = []
    /// 命中重算代际：慢结果回来时已被更新的输入超越则丢弃
    @State private var matchGeneration = 0
    @State private var exportNote: String?
    /// 已展开的轨迹消息 id（切会话时清空，避免新会话同 id 意外展开）
    @State private var expandedTrails: Set<Int> = []
    /// 「本会话产出」是否展开全部（默认只显示前 5 条，避免几十条产出把对话区压没）
    @State private var artifactsExpanded = false

    enum RoleFilter: String, CaseIterable {
        case all = "全部"
        case user = "用户"
        case assistant = "助手"

        /// Tray label: the person reading is "我", the other side is the agent's own product
        /// name (Claude Code, Codex, …) instead of the generic "用户 / 助手".
        func label(for source: AgentSource?) -> String {
            switch self {
            case .all: return "全部"
            case .user: return "我"
            case .assistant: return source?.displayName ?? "助手"
            }
        }
    }

    var body: some View {
        Group {
            if let session = service.selected {
                VStack(spacing: 0) {
                    header(session)
                    overviewCard(session)
                    // 上下文用量卡片：nil（trae/antigravity/未算完）时不渲染；
                    // .id 让切会话时折叠态归零（同 artifactsExpanded 的防护思路）
                    if let breakdown = service.contextBreakdown {
                        ContextUsageCard(breakdown: breakdown)
                            .id(session.id)
                    }
                    searchBar
                    Divider()
                    // 目录栏用 HSplitView：分隔线可拖拽调宽（与左栏会话列表同款交互），
                    // minWidth 保证拖到最窄也不挤坏时间戳，maxWidth 防止吞掉对话区
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
                    "删除会话「\(session.name ?? String(session.id.prefix(8)))」？transcript 文件会移入废纸篓，可恢复。",
                    isPresented: $confirmingDelete, titleVisibility: .visible
                ) {
                    Button("删除", role: .destructive) {
                        service.deleteSessions([session])
                    }
                    Button("取消", role: .cancel) {}
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.brandFg.opacity(0.4))
                    Text("选择左侧会话查看对话记录")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 挂在 Group 上：经由"清空选择"中转的切换也能清空轨迹展开态（新会话同 id 不误展开）
        .onChange(of: service.selected?.id) { _, _ in
            expandedTrails = []
            artifactsExpanded = false
        }
        // 全文命中跳转：transcript 加载完成后滚到目标消息（延迟一拍等 LazyVStack 布局）
        .onChange(of: service.transcriptLoading) { _, loading in
            guard !loading else { return }
            // 首次加载 / 切会话 / 「加载全部」都从这里对新正文重算搜索命中
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

    /// 按角色筛选后的消息流（搜索不过滤、只高亮+跳转）
    private var displayMessages: [TranscriptMessage] {
        switch roleFilter {
        case .all: return service.transcript
        case .user: return service.transcript.filter { $0.role == .user }
        case .assistant: return service.transcript.filter { $0.role == .assistant }
        }
    }

    /// 重算搜索命中：250ms 防抖（打字路径）+ 后台全文扫描 + 代际防串。
    /// 算完自动跳到第一处命中（保持原 computed 版本的交互语义）。
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

    // MARK: - 头部

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
                    Label("恢复会话", systemImage: "play.fill")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
                .help("在 Terminal 中执行恢复命令")
                Button {
                    confirmingDelete = true
                } label: {
                    Label("删除会话", systemImage: "trash")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!session.source.supportsSessionDeletion)
                .help(session.source.supportsSessionDeletion
                    ? "移入废纸篓，可恢复"
                    : "\(session.source.displayName) 会话存于共享数据库，暂不支持删除")
                Menu {
                    Button("复制为 Markdown") { copyMarkdown(session) }
                    Button("导出为 .md 文件…") { exportMarkdown(session) }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("导出对话记录")
                if let onOpenLineage {
                    Button {
                        onOpenLineage(.list)
                    } label: {
                        Label("轮次血缘", systemImage:
                            "point.3.filled.connected.trianglepath.dotted")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help("按轮次看它做了什么、哪一轮的提示词该改")
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showTOC.toggle() }
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help(showTOC ? "隐藏对话目录" : "显示对话目录")
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
                // 共享库的源（opencode / hermes）没有「本会话的转录文件」，展示库名反而误导
                if !session.source.usesSharedSessionDatabase {
                    metaItem("doc.text",
                             URL(fileURLWithPath: session.transcriptPath).lastPathComponent)
                }
                Spacer(minLength: 0)
            }
            terminalHistoryRow(session)
            artifactsRow(session)
            // resume 命令条
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
                .help("复制恢复命令")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// 终端归属：这个会话在哪些终端里跑过。换终端 resume 过就会有多条，
    /// 逐条给跳转按钮（该终端已退出则置灰）。一条都没有时整行不出现。
    @ViewBuilder
    private func terminalHistoryRow(_ session: AgentSessionInfo) -> some View {
        let history = service.terminalHistory(for: session)
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if history.count > 1 {
                    Text("曾在 \(history.count) 个终端运行")
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

    /// 「本会话产出」的一条：记忆或计划，合并排序/分页用同一列表
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

    /// 每次最多展示的产出条数；header 在 ScrollView 外，几十条产出会把对话区压没
    private static let artifactsPageSize = 5

    /// 本会话产出：记忆（originSessionId/relatedSessions 命中）+ 计划（物化边车 sessionId 命中）
    @ViewBuilder
    private func artifactsRow(_ session: AgentSessionInfo) -> some View {
        let memories = skillMemory.memories(relatedTo: session.id)
        let planEntries = plans.plans(forSession: session.id)
        let items: [Artifact] = memories.map(Artifact.memory) + planEntries.map(Artifact.plan)
        if !items.isEmpty {
            let visible = artifactsExpanded ? items : Array(items.prefix(Self.artifactsPageSize))
            let hiddenCount = items.count - visible.count
            VStack(alignment: .leading, spacing: 3) {
                Text("本会话产出")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                ForEach(visible) { item in
                    artifactLine(item)
                }
                if hiddenCount > 0 {
                    Text("还有 \(hiddenCount) 条")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                        .onTapGesture { artifactsExpanded = true }
                        .help("展开全部本会话产出")
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
                note: isInstruction ? "指令" : "记忆"
            ) {
                NotificationCenter.default.post(
                    name: .eurekaRevealKnowledge, object: memory.path,
                    userInfo: ["kind": isInstruction ? "instruction" : "memory"])
            }
        case .plan(let plan):
            artifactLine(icon: "list.bullet.clipboard", title: plan.title, note: "计划") {
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
        .help("在对应页面打开")
    }

    /// 跳转按钮：只把终端**应用**带到前台（不选标签页，因此不需要自动化/辅助功能权限）
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
            ? "切到 \(binding.terminalName)（只激活应用，多标签时需自行找到该标签）"
            : "\(binding.terminalName) 当前未在运行")
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

    // MARK: - 概览卡

    @ViewBuilder
    private func overviewCard(_ session: AgentSessionInfo) -> some View {
        let cost = service.costs[session.id]
        HStack(spacing: 24) {
            overviewStat("消息", "\(service.transcript.count)")
            overviewStat("提问", "\(userMessages.count)")
            if let cost {
                overviewStat("Tokens", formatTokens(cost.totalTokens))
                if let usd = cost.costUSD {
                    overviewStat("费用", formatCost(usd), color: Theme.cost)
                }
            }
            if let span = session.duration, span >= 60 {
                overviewStat("时长", formatDuration(span))
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

    // MARK: - 搜索栏

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
            SearchField(placeholder: "在对话中搜索", text: $searchQuery, maxWidth: 340)
                .onChange(of: searchQuery) { _, _ in
                    recomputeMatches(debounce: true)
                }
            if !matches.isEmpty {
                Text("\(min(matchIndex + 1, matches.count)) / \(matches.count)")
                    .font(Theme.font.themedMono(11, .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                CardActionButton(icon: "chevron.up", size: 22, help: "上一处命中") {
                    matchIndex = (matchIndex - 1 + matches.count) % matches.count
                    jumpToCurrentMatch()
                }
                CardActionButton(icon: "chevron.down", size: 22, help: "下一处命中") {
                    matchIndex = (matchIndex + 1) % matches.count
                    jumpToCurrentMatch()
                }
            } else if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("无匹配")
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

    // MARK: - 导出

    private func copyMarkdown(_ session: AgentSessionInfo) {
        let md = TranscriptMarkdown.render(session: session, messages: service.transcript)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        exportNote = "已复制 Markdown 到剪贴板"
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
            exportNote = "已导出 \(url.lastPathComponent)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exportNote = nil }
        }
    }

    // MARK: - 对话记录流

    private func transcriptPane(_ session: AgentSessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Pane header in the same type as every other section header (Theme.font so brutal
            // gets Space Grotesk / Space Mono here too)
            HStack(spacing: 7) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("对话记录")
                    .font(Theme.font.themed(12, .semibold))
                Text(service.transcript.count.formatted())
                    .font(Theme.font.themedMono(10.5, .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.brandFill(0.12)))
                    .foregroundStyle(Theme.brandFg)
                if service.transcriptTruncated {
                    Text("仅显示前 \(service.transcript.count) 条")
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(Theme.goldFg)
                    Button("加载全部") {
                        service.loadFullTranscript()
                    }
                    .buttonStyle(.borderless)
                    .font(Theme.font.themed(10.5, .medium))
                    .foregroundStyle(Theme.brandFg)
                    .help("超长会话默认按预算截断，点击完整加载（大文件会稍慢）")
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if service.transcriptLoading {
                ProgressView("正在解析对话记录…")
                    .font(Theme.font.themed(11))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.transcript.isEmpty {
                Text("没有可显示的消息")
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

    // MARK: - 对话目录

    private var tocPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "list.number")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("对话目录")
                    .font(Theme.font.themed(12, .semibold))
                Spacer(minLength: 4)
                Text("\(userMessages.count) 条")
                    .font(Theme.font.themedMono(10.5, .medium))
                    .foregroundStyle(.secondary)
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

/// 目录行：序号圆徽 + 时间 + 提问摘录。宽度由外层 HSplitView 拖拽决定，
/// 文字随宽自适应换行（最多 3 行，尾部省略），hover 有轻高亮。
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
                // 胶囊而非定宽圆：三位数以上的序号（长会话到 400+）不能被截成「4…」
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
    /// 对话目录 → 消息流跳转（携带消息 id）
    static let eurekaJumpToMessage = Notification.Name("eurekaJumpToMessage")
}

// MARK: - 消息行

/// One transcript message: a 22pt avatar on the left, then name + time and the body in a card.
/// The reader is "我" (person tile on the brand colour); the other side is the agent itself —
/// its product name and official logo tile — rather than a generic "助手". User bodies sit on a
/// brand tint, agent bodies on the surface colour with a hairline edge, so two agent replies in
/// a row read as two blocks instead of one run of text. Timestamps stay in the header; the
/// copy button appears on hover without covering the body.
private struct MessageRowView: View {
    let message: TranscriptMessage
    /// Which agent produced this transcript; names and draws the assistant side
    let source: AgentSource
    var isMatch = false
    @Binding var expandedTrails: Set<Int>

    @State private var hovering = false
    @State private var copied = false

    /// Width of the avatar column; secondary rows indent by it to line up with message bodies
    private static let avatarSize: CGFloat = 22
    private static let avatarGap: CGFloat = 10

    private enum Avatar {
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
                name: "我", avatar: .symbol("person.fill", Theme.brandFg), tint: Theme.brandFg,
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
                name: "出错", avatar: .symbol("exclamationmark.triangle.fill", Theme.failureRed),
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
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Theme.font.themed(10, .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("复制消息原文")
                .transition(.opacity)
            }
        }
        .frame(minHeight: Self.avatarSize)
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

// 富文本正文渲染已抽到共享组件 MarkdownRichText.swift（会话/记忆/技能/计划共用）
