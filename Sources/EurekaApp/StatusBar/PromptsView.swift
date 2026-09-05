import AppKit
import EurekaIngest
import EurekaKit
import SwiftUI

/// Prompt 库：从全部会话提取的用户提问，统一浏览/搜索/复用。
/// 列表 = 收藏星标 + 来源徽标 + 首行标题 + 项目/会话 + 时间；详情 = 全文 + 复制/回跳会话。
struct PromptsView: View {
    @ObservedObject var service: PromptsService
    /// 跳回所属会话（transcript 定位到该提问）
    var sessionBrowser: SessionBrowserService
    /// Prompt 毕业（升级为技能/指令）走知识面服务
    var skillMemory: SkillMemoryService

    /// 内嵌详情页当前展示的条目（nil = 列表）
    @State private var detail: PromptEntry?
    @State private var deleting: PromptEntry?
    /// 来源筛选（nil = 全部）
    @State private var selectedSource: AgentSource?
    /// 已展开的高频重复组（指纹集合）
    @State private var expandedGroups: Set<String> = []
    /// 「最费劲」排序：severity 降序 → 步数降序（找出最该改写/模板化的提问）
    @State private var effortSort = false

    /// 搜索 + 来源 + 收藏筛选后的列表（service 已按 first_seen 倒序）；
    /// 「最费劲」开关按评价重排（无评价的排后，保持原相对顺序）
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
            return lhs.offset < rhs.offset  // 稳定排序：同分保持时间序
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
        .confirmationDialog(
            deleting.map { "从 Prompt 库移除「\($0.title)」？源会话不受影响。" } ?? "",
            isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive) {
                if let entry = deleting {
                    service.delete(entry.id)
                    if detail?.id == entry.id { detail = nil }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 顶部栏

    private var header: some View {
        HStack(spacing: 12) {
            Text("Prompt 库").font(.system(size: 15, weight: .bold))
            SearchField(
                placeholder: "搜索提问", text: $service.searchText,
                scanning: service.scanning, resultCount: service.prompts.count)
            Spacer(minLength: 12)
            Button {
                service.favoritesOnly.toggle()
            } label: {
                Image(systemName: service.favoritesOnly ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(service.favoritesOnly ? Theme.gold : .secondary)
            }
            .buttonStyle(.borderless)
            .help(service.favoritesOnly ? "显示全部提问" : "只看收藏")
            Button {
                effortSort.toggle()
            } label: {
                Image(systemName: "flame")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(effortSort ? Color.orange : .secondary)
            }
            .buttonStyle(.borderless)
            .help(effortSort
                ? "恢复时间排序"
                : "最费劲的提问排前（引来纠偏/走弯路多/步数多——最该改写或模板化）")
            ScanStatusLabel(
                scanning: service.scanning, phase: service.scanPhase,
                lastScanAt: service.lastScanAt)
            RefreshButton(help: "重新提取（增量：只解析有新消息的会话）") { service.refresh() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        // 每次渲染只算一遍：sourceCounts / filtered 都是 O(全库) 扫描，
        // 之前 statsCard + 每个来源 chip 各算一次，库一大渲染就开始拖
        let counts = sourceCounts
        let sources = counts.sorted { $0.value > $1.value }.map(\.key)
        let rows = filtered
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statsCard(counts: counts, sourceCount: sources.count)
                SourceFilterBar(
                    selected: $selectedSource,
                    allLabel: "全部", allIcon: "text.quote",
                    totalCount: service.totalCount,
                    sources: sources,
                    count: { counts[$0] ?? 0 })
                if rows.isEmpty && service.groups.isEmpty {
                    emptyState.padding(.top, 40)
                } else if service.isSearching {
                    // 搜索 = 平铺命中（含被默认折叠的分类，找什么都能找到）
                    promptList(rows)
                } else {
                    // 三段式：收藏（用户资产）→ 高频重复（模板/技能候选）→ 最近
                    let favorites = rows.filter(\.favorite)
                    let recent = rows.filter { !$0.favorite }
                    if !favorites.isEmpty {
                        sectionHeader("star.fill", "收藏", favorites.count)
                        promptList(favorites)
                    }
                    if selectedSource == nil, !service.groups.isEmpty {
                        sectionHeader(
                            "repeat", "高频重复", service.groups.count,
                            note: "反复在问的同一件事 —— 升级为技能/指令的头号候选")
                        groupsList
                    }
                    HStack(spacing: 8) {
                        sectionHeader("clock", "最近", recent.count)
                        Spacer(minLength: 8)
                        Toggle(isOn: Binding(
                            get: { service.showAll },
                            set: { service.showAll = $0 })) {
                            Text("显示全部（含琐碎/长粘贴）")
                                .font(Theme.font.themed(10))
                                .foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.mini)
                        .help("默认折叠 \(service.foldedCount) 条低复用价值条目（琐碎短语/日志粘贴/历史噪音）")
                    }
                    if recent.isEmpty {
                        Text("这个来源近期没有可复用的提问")
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

    /// 段落标题：图标 + 名称 + 计数
    private func sectionHeader(
        _ icon: String, _ title: String, _ count: Int, note: String? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
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

    /// 一段条目列表（懒加载：prompt 库是首个数据量可上万的条目面，
    /// 普通 VStack 会在打开页签时一次性物化全部行、卡死主线程）
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

    /// 高频重复组：组行（代表标题 + ×N · M 个项目）点击展开成员
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
            unit: "提问",
            subtitle: "\(sourceCount) 个来源 · 收藏 \(service.favoriteCount)",
            distributionTitle: "来源分布",
            segments: top.map {
                .init(label: $0.key.displayName, count: $0.value, color: Theme.brand)
            },
            showBar: false,
            trailingNote: service.foldedCount > 0
                ? "已折叠 \(service.foldedCount) 条低价值条目" : nil)
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

    /// 跳回所属会话（切页签 + 滚动定位到该提问）。
    /// 与命令面板 transcript 命中同款顺序：先发通知切页+选中，再补 messageIdx 定位
    /// （pendingJump 在 transcript 加载完成后被 SessionDetailView 消费）。
    private func jumpToSession(_ entry: PromptEntry) {
        NotificationCenter.default.post(name: .eurekaRevealSession, object: entry.sessionId)
        sessionBrowser.revealMessage(sessionId: entry.sessionId, messageIdx: entry.messageIdx)
    }

    /// 跨页直达落点：按 id 找到条目并打开详情（找不到不清空——扫描可能还没跑到）
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
                Text("正在提取用户提问…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("首次提取需解析全部会话记录，可能需要一两分钟；"
                    + "之后为增量提取，秒级完成。可先切到其他页签，提取在后台继续。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(
                icon: "text.quote",
                title: service.isSearching || service.favoritesOnly || selectedSource != nil
                    ? "没有匹配的提问" : "还没有提取到提问",
                hint: service.isSearching || service.favoritesOnly || selectedSource != nil
                    ? nil
                    : "提问从各 Agent 的会话记录中自动提取（会话页签扫描完成后开始）")
        }
    }
}

// MARK: - 评价呈现的共享文案

/// 规则 id → 短标签（行级色点旁的首要问题词 / 详情证据卡的信号名）
func promptRuleLabel(_ rule: String) -> String {
    switch rule {
    case "explore-heavy": return "找文件开销大"
    case "reread": return "反复回读"
    case "rework": return "改后回看"
    case "retry": return "反复重试"
    case "churn": return "反复改同文件"
    case "clarify": return "反问澄清"
    case "corrective": return "引来纠偏"
    case "reformulated": return "重述打转"
    case "outcome-error": return "报错收尾"
    default: return rule
    }
}

/// 规则 id → 指回提示词的改进建议（详情证据卡用；与 TurnDiagnostics 的 advice 同口径）
func promptRuleAdvice(_ rule: String) -> String {
    switch rule {
    case "explore-heavy": return "提示词里直接点名文件/目录，能省掉定位开销"
    case "reread": return "上下文没一次给够：把相关文件/约束一次性给全"
    case "rework": return "改之前没看清：给出确切的改动位置"
    case "retry": return "验收标准不清：把「怎样算成功」写进提示词"
    case "churn": return "同一文件被反复改：先要一份改动方案再落笔"
    case "clarify": return "提问有歧义：把选择项与约束提前写清"
    case "corrective": return "下一条提问在纠偏——这条没有一次说清"
    case "reformulated": return "随后换词重问了同一件事：补足上下文或验收标准"
    case "outcome-error": return "本轮以 API 错误收尾"
    default: return ""
    }
}

/// 首要问题词：纠偏最能说明问题，其次取第一条命中的规则
func promptPrimaryRule(_ eval: PromptEval) -> String? {
    if eval.ruleIds.contains("corrective") { return "corrective" }
    return eval.ruleIds.first
}

func promptSeverityColor(_ severity: TurnDiagnostics.Severity) -> Color {
    severity == .bad ? .red : .orange
}

// MARK: - 列表行

/// 一行提问：收藏星标 + 首行标题 + 来源/项目/时间副标 + 悬停复制/终端运行/回跳操作。
private struct PromptRow: View {
    let entry: PromptEntry
    let service: PromptsService
    /// 评价结果；nil = 该源不可评价或未重扫（静默无点，不显示"clean"）
    var eval: PromptEval?
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onJump: () -> Void
    /// 在终端以此提问启动新会话；nil = 该源不支持（按钮不显示）
    var onRun: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                service.toggleFavorite(entry.id)
            } label: {
                Image(systemName: entry.favorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(entry.favorite ? Theme.gold : .secondary.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .help(entry.favorite ? "取消收藏" : "收藏")

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(Theme.font.themed(12.5, .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    SourceBadge(source: entry.source, size: 11)
                    // 只在 notice/bad 时出点（不给每条判分；缺行静默）
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
                        .help("这条提问执行得费劲（点开看证据）：" +
                            eval.ruleIds.map(promptRuleLabel).joined(separator: "、"))
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
                        Text("已用 \(entry.useCount) 次")
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
            if hovering {
                HStack(spacing: 10) {
                    if let onRun {
                        Button(action: onRun) {
                            Image(systemName: "play.fill").font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help("在终端以此提问启动新会话（\(entry.source.displayName)）")
                    }
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("复制提问原文")
                    Button(action: onJump) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("在所属会话中查看")
                }
                .foregroundStyle(.secondary)
            }
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

// MARK: - 高频重复组行

/// 组行：代表标题 + 出现次数/项目数徽章 + 展开箭头。点击整行切换展开。
private struct PromptGroupRow: View {
    let group: PromptGroup
    /// 组内执行费劲（severity ≥ notice）的次数——"反复问且每次都费劲" = 最该模板化
    let effortCount: Int
    let expanded: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 11)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.representative.title)
                    .font(Theme.font.themed(12.5, .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    SourceBadge(source: group.representative.source, size: 11)
                    Text("出现 \(group.count) 次")
                        .font(Theme.font.themedMono(10))
                        .foregroundStyle(Theme.brandFg)
                    if effortCount > 0 {
                        Text("\(effortCount) 次费劲")
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(.orange)
                            .help("反复在问且执行费劲——最该模板化或升级为技能的候选")
                    }
                    if group.projectCount > 1 {
                        Text("跨 \(group.projectCount) 个项目")
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

// MARK: - 详情页

/// 提问详情：全文可选中复制 + 标签编辑 + 复制/终端启动/毕业（技能·指令）/回跳/移除。
private struct PromptDetailView: View {
    let entry: PromptEntry
    let service: PromptsService
    let skillMemory: SkillMemoryService
    let onBack: () -> Void
    let onDelete: () -> Void
    let onJumpToSession: () -> Void

    @State private var newTag = ""
    @State private var copied = false
    /// 毕业表单（nil = 未打开）
    @State private var graduation: GraduationMode?
    /// 毕业/启动结果的短暂提示
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
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("返回列表")
            SourceBadge(source: entry.source, size: 14)
            Text(entry.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let session = service.sessionName(for: entry) {
                Text(session)
                    .font(.system(size: 10))
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
            Text("\(entry.text.count) 字")
            Spacer(minLength: 0)
        }
        .font(Theme.font.themed(10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func metaItem(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text)
        }
    }

    /// 「实际效果」证据卡：这条 prompt 让 agent 付出了什么、你事后满不满意。
    /// 三档结论 + 证据 + 建议，不打综合分（评价体系的呈现原则）。
    private func evalCard(_ eval: PromptEval) -> some View {
        let capability = PromptEvalCapability.level(for: entry.source)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("实际效果")
                    .font(Theme.font.themed(11, .semibold))
                    .foregroundStyle(.secondary)
                if eval.severity >= .notice {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(promptSeverityColor(eval.severity))
                            .frame(width: 6, height: 6)
                        Text(eval.severity == .bad ? "费劲" : "有摩擦")
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(promptSeverityColor(eval.severity))
                    }
                }
                Spacer(minLength: 4)
                if capability == .followupOnly {
                    Text("该源无工具轨迹，仅纠偏信号")
                        .font(Theme.font.themed(9))
                        .foregroundStyle(.tertiary)
                }
            }
            // 计量行
            HStack(spacing: 12) {
                if capability != .followupOnly {
                    Text("\(eval.stepCount) 步工具")
                    if eval.errorSteps > 0 {
                        Text("\(eval.errorSteps) 步失败").foregroundStyle(.red)
                    }
                }
                if let duration = eval.duration, duration >= 5 {
                    Text(formatDuration(duration))
                }
                if eval.outcome == "error" {
                    Text("报错收尾").foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
            .font(Theme.font.themedMono(10))
            .foregroundStyle(.secondary)
            // 信号与建议（逐条证据）
            let rules = eval.ruleIds.filter { $0 != "outcome-error" }
            if !rules.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rules, id: \.self) { rule in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .padding(.top, 1.5)
                            Text("\(promptRuleLabel(rule))：\(promptRuleAdvice(rule))")
                                .font(Theme.font.themed(10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else if eval.severity == .clean {
                Text("一次说清，执行顺畅")
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(.secondary)
            }
            // 静态结构提示（弱先验，不参与结论）
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
            if flags.contains(.acceptance) { notes.append("✓ 带验收标准") }
            if flags.contains(.filePath) { notes.append("✓ 点名了文件") }
            if flags.contains(.deicticStart) {
                notes.append("△ 指代词开头——离开会话即失效，模板化前补上下文")
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
            ? String(format: "%.1f 小时", seconds / 3600)
            : seconds >= 60
                ? String(format: "%.0f 分钟", seconds / 60)
                : String(format: "%.0f 秒", seconds)
    }

    private var tagsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("标签")
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
                                .font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                    }
                    .foregroundStyle(Theme.goldFg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.gold.opacity(0.12)))
                }
                TextField("添加标签", text: $newTag)
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
                Button {
                    service.copyToPasteboard(entry.id)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制提问",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
                if service.launchCommand(for: entry.id) != nil {
                    Button {
                        service.launchInTerminal(entry.id)
                        note("已在 Terminal 中启动新会话")
                    } label: {
                        Label("在终端启动新会话", systemImage: "play.fill")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help("Terminal 中以此提问开一个新的 \(entry.source.displayName) 会话"
                        + (entry.cwd.map { "（\($0)）" } ?? ""))
                }
                Button {
                    graduation = .skill
                } label: {
                    Label("升级为技能", systemImage: "graduationcap")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("把这条提问沉淀为技能（SKILL.md）——以后 agent 自动加载，不用再重复输入")
                Button {
                    graduation = .instruction
                } label: {
                    Label("升级为指令", systemImage: "text.book.closed")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("沉淀为持久指令，之后每次会话自动加载（Claude 追加到 ~/.claude/CLAUDE.md；Codex 追加到 AGENTS.md）")
                Button(action: onJumpToSession) {
                    Label("在会话中查看", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("切到会话页签并定位到这条提问")
                Spacer(minLength: 0)
                if entry.useCount > 0 {
                    Text("已使用 \(entry.useCount) 次"
                        + (entry.lastUsedAt.map { " · 最近 " + $0.formatted(.dateTime.month().day()) } ?? ""))
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                }
                Button(role: .destructive, action: onDelete) {
                    Label("移除", systemImage: "trash").font(.system(size: 11))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(.red)
                .help("从 Prompt 库移除（源会话不受影响）")
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

// MARK: - 毕业表单

/// 把一条提问沉淀为技能或持久指令：选目标源 + 命名 → 写盘 → 跳到对应知识页。
private struct PromptGraduationSheet: View {
    let mode: PromptDetailView.GraduationMode
    let entry: PromptEntry
    let skillMemory: SkillMemoryService
    /// 完成回调：message 非 nil 时显示在详情页（nil = 用户取消）
    let onDone: (String?) -> Void

    @State private var name = ""
    @State private var target: AgentSource = .claude
    @State private var running = false
    @State private var errorNote: String?

    /// 指令毕业只开放 PromptInstructionDestination 裁定的源（claude 追加 ~/.claude/CLAUDE.md /
    /// codex 追加 AGENTS.md）；技能毕业全源可用（SKILL.md 格式同构）
    private var targets: [AgentSource] {
        mode == .skill ? AgentSource.allCases : PromptInstructionDestination.supportedSources
    }

    /// 指令模式下当前目标的落点说明（切换目标源时跟着变）
    private var instructionHint: String {
        guard let destination = PromptInstructionDestination.destination(for: target) else {
            return "该源没有可写的持久指令文件。"
        }
        return "追加一节到 \(destination.fileLabel)（写前自动备份），之后 \(target.displayName) 每次会话自动加载。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .skill ? "升级为技能" : "升级为指令")
                .font(.system(size: 14, weight: .bold))
            Text(mode == .skill
                ? "把这条提问写成 SKILL.md —— 之后 agent 按描述自动加载，或用 /名称 显式调用。"
                : instructionHint)
                .font(Theme.font.themed(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("目标", selection: $target) {
                ForEach(targets, id: \.self) { Text($0.displayName) }
            }
            .pickerStyle(.menu)
            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
            if let errorNote {
                Text(errorNote)
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(running ? "写入中…" : "创建") { graduate() }
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
            // 默认目标 = 提问所属的源（在支持列表里的话）
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
                       failure: "创建失败：目标已存在同名技能或目录不可写")
            }
        case .instruction:
            // reveal 的 kind 随落点走（两个落点在索引里都是指令，落指令页；
            // 早先按 "memory" reveal 会跳到记忆页找不到目标）
            let kind = PromptInstructionDestination.destination(for: target)?.knowledgeKind
                ?? "instruction"
            skillMemory.graduatePromptToInstructions(
                source: target, name: trimmed, body: entry.text
            ) { path in
                finish(path: path, kind: kind, failure: "写入失败：指令文件读不出来或目录不可写")
            }
        }
    }

    private func finish(path: String?, kind: String, failure: String) {
        running = false
        guard let path else {
            errorNote = failure
            return
        }
        // 跳到对应知识页并定位到新文件
        NotificationCenter.default.post(
            name: .eurekaRevealKnowledge, object: path, userInfo: ["kind": kind])
        onDone(kind == "skill"
            ? "已升级为 \(target.displayName) 技能"
            : "已追加到 \(target.displayName) 指令文件 \(URL(fileURLWithPath: path).lastPathComponent)")
    }
}
