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
    @State private var exportNote: String?
    /// 已展开的轨迹消息 id（切会话时清空，避免新会话同 id 意外展开）
    @State private var expandedTrails: Set<Int> = []
    /// 「本会话产出」是否展开全部（默认只显示前 5 条，避免几十条产出把对话区压没）
    @State private var artifactsExpanded = false

    enum RoleFilter: String, CaseIterable {
        case all = "全部"
        case user = "用户"
        case assistant = "助手"
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
                                .frame(minWidth: 160, idealWidth: 210, maxWidth: 360)
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
            guard !loading, let pending = service.consumePendingJump() else { return }
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

    /// 搜索命中的消息 id（在 displayMessages 内）
    private var matchIDs: [Int] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return displayMessages
            .filter { $0.text.lowercased().contains(query) }
            .map(\.id)
    }

    // MARK: - 头部

    private func header(_ session: AgentSessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                SourceBadge(source: session.source, size: 14)
                Text(session.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
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
        HStack(spacing: 16) {
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

    // MARK: - 搜索栏

    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $roleFilter) {
                ForEach(RoleFilter.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .controlSize(.mini)
            .onChange(of: roleFilter) { _, _ in
                matchIndex = 0
                jumpToCurrentMatch()
            }

            Image(systemName: "magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            TextField("在对话中搜索", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onChange(of: searchQuery) { _, _ in
                    matchIndex = 0
                    jumpToCurrentMatch()
                }
            if !matchIDs.isEmpty {
                Text("\(min(matchIndex + 1, matchIDs.count))/\(matchIDs.count)")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    matchIndex = (matchIndex - 1 + matchIDs.count) % matchIDs.count
                    jumpToCurrentMatch()
                } label: { Image(systemName: "chevron.up").font(.system(size: 9)) }
                .buttonStyle(.borderless)
                Button {
                    matchIndex = (matchIndex + 1) % matchIDs.count
                    jumpToCurrentMatch()
                } label: { Image(systemName: "chevron.down").font(.system(size: 9)) }
                .buttonStyle(.borderless)
            } else if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("无匹配")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 7)
    }

    private func jumpToCurrentMatch() {
        guard matchIndex < matchIDs.count else { return }
        NotificationCenter.default.post(name: .eurekaJumpToMessage, object: matchIDs[matchIndex])
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
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("对话记录")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(service.transcript.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.brand.opacity(0.12)))
                    .foregroundStyle(Theme.brandFg)
                if service.transcriptTruncated {
                    Text("仅显示前 \(service.transcript.count) 条")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()

            if service.transcriptLoading {
                ProgressView("正在解析对话记录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.transcript.isEmpty {
                Text("没有可显示的消息")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // 文档式排列：统一左对齐，角色标签区分消息来源
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(displayMessages) { message in
                                MessageRowView(
                                    message: message,
                                    isMatch: matchIDs.contains(message.id),
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
            HStack(spacing: 5) {
                Image(systemName: "list.number")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("对话目录")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                Text("\(userMessages.count) 条")
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
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(hovering ? Theme.onBrand : Theme.brandFg)
                    .frame(width: 16, height: 16)
                    .background(
                        Circle().fill(hovering ? Theme.brand : Theme.brand.opacity(0.1)))
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
    /// 对话目录 → 消息流跳转（携带消息 id）
    static let eurekaJumpToMessage = Notification.Name("eurekaJumpToMessage")
}

// MARK: - 消息行

/// 对话流式消息行：用户与助手统一左对齐、文档式排列，
/// 通过角色标签 + 微妙底色区分（不再用聊天气泡框）。
/// 时间戳常驻角色标签行、复制按钮 hover 浮现，不遮挡正文。
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
                roleHeader(label: "用户", icon: "person.fill", color: Theme.brandFg)
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
                roleHeader(label: "助手", icon: "sparkles", color: .secondary)
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
                roleHeader(label: "错误", icon: "exclamationmark.triangle.fill", color: .red)
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

    /// 角色标签行：图标 + 角色名 + 时间戳（常驻、细弱）+ 复制按钮（hover 浮现）
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
                .help("复制消息原文")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 2)
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }
}

// 富文本正文渲染已抽到共享组件 MarkdownRichText.swift（会话/记忆/技能/计划共用）
