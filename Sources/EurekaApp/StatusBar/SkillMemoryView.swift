import EurekaIngest
import EurekaKit
import EurekaStore
import SwiftUI

/// 技能 & 记忆管理：统计瓦片（点击按 CLI 筛选）+ Top 技能分析卡 + 卡片网格 + 内嵌详情，
/// 与「计划」「用量」页同一套交互语言。技能卡片右上角为启停状态方块（绿=启用/灰=停用，点击切换）。
/// Skills / Memory 两个同级页签共用此视图，由 mode 决定只显示技能或只显示记忆。
struct SkillMemoryView: View {
    /// 页签模式：技能页 or 记忆页
    enum Mode { case skills, memory }

    @ObservedObject var service: SkillMemoryService
    let mode: Mode
    @ObservedObject var usageService: UsageService

    /// 内嵌技能详情（卡片 / 排行行点击进入；nil = 列表）
    @State private var detail: SkillDetailTarget?
    /// 内嵌记忆详情（nil = 列表）
    @State private var memoryDetail: MemoryEntry?
    /// 来源筛选（nil = 全部）
    @State private var selectedSource: AgentSource?
    /// Top 技能排行时间档（今日/本周/本月/全部/自定义）
    @State private var period: UsageService.DashboardPeriod = .week
    @State private var customFrom = Date().addingTimeInterval(-7 * 86400)
    @State private var customTo = Date()

    @State private var creating: CreateTarget?
    @State private var newName = ""
    @State private var deleting: DeleteTarget?

    var body: some View {
        Group {
            if let target = detail {
                SkillDetailView(
                    target: target, service: service, usageService: usageService,
                    onBack: { withAnimation(.easeOut(duration: 0.15)) { detail = nil } },
                    onDelete: { deleting = .skill($0) })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let memory = memoryDetail {
                MemoryDetailView(
                    memory: memory, service: service,
                    onBack: { withAnimation(.easeOut(duration: 0.15)) { memoryDetail = nil } },
                    onDelete: { deleting = .memory(memory) })
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
            if mode == .skills {
                usageService.loadSkillStats()
                reloadRanking()
            }
        }
        .onChange(of: period) { _ in reloadRanking() }
        .onChange(of: customFrom) { _ in reloadRanking() }
        .onChange(of: customTo) { _ in reloadRanking() }
        .onChange(of: selectedSource) { _ in reloadRanking() }
        .alert("新建" + (creating?.label ?? ""), isPresented: creatingBinding) {
            TextField("名称", text: $newName)
            Button("创建") {
                if let creating, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    if creating.isSkill {
                        service.createSkill(source: creating.source, name: newName)
                    } else {
                        service.createMemory(source: creating.source, name: newName)
                    }
                }
                newName = ""
            }
            Button("取消", role: .cancel) { newName = "" }
        }
        .confirmationDialog(
            deleting.map { "删除「\($0.title)」？文件会移入废纸篓，可恢复。" } ?? "",
            isPresented: deletingBinding, titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                deleting?.perform(service)
                // 从内嵌详情发起的删除 → 回列表
                detail = nil
                memoryDetail = nil
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 顶部栏

    private var header: some View {
        searchRow
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            TextField(mode == .skills ? "搜索技能" : "搜索记忆", text: $service.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if service.scanning {
                ProgressView().controlSize(.mini)
            }
            Menu {
                if mode == .skills {
                    Button("Claude 技能") { startCreate(.claude, isSkill: true, "Claude 技能") }
                    Button("Codex 技能") { startCreate(.codex, isSkill: true, "Codex 技能") }
                    Button("OpenCode 技能") { startCreate(.opencode, isSkill: true, "OpenCode 技能") }
                    Button("Grok 技能") { startCreate(.grok, isSkill: true, "Grok 技能") }
                    Button("Antigravity 技能") { startCreate(.antigravity, isSkill: true, "Antigravity 技能") }
                    Button("Kimi 技能") { startCreate(.kimi, isSkill: true, "Kimi 技能") }
                    Button("Gemini 技能") { startCreate(.gemini, isSkill: true, "Gemini 技能") }
                    Button("Qwen 技能") { startCreate(.qwen, isSkill: true, "Qwen 技能") }
                } else {
                    Button("Claude 记忆") { startCreate(.claude, isSkill: false, "Claude 记忆") }
                    Button("Codex 指令（AGENTS.md）") {
                        service.createMemory(source: .codex, name: "AGENTS")
                    }
                    Button("Grok 记忆") { startCreate(.grok, isSkill: false, "Grok 记忆") }
                    // kimi/gemini 记忆 = 单一全局文件，无需命名 → 直接创建并刷新
                    Button("Kimi 记忆（AGENTS.md）") { service.createMemory(source: .kimi, name: "AGENTS") }
                    Button("Gemini 记忆（GEMINI.md）") { service.createMemory(source: .gemini, name: "GEMINI") }
                    Button("Qwen 记忆") { startCreate(.qwen, isSkill: false, "Qwen 记忆") }
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: - 主体

    private let gridColumns = [GridItem(.adaptive(minimum: 170), spacing: 10)]

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                statsTiles
                if mode == .skills {
                    topSkillsCard
                }
                if visibleSources.isEmpty {
                    emptyState
                        .padding(.top, 40)
                } else {
                    switch mode {
                    case .skills: skillsSections
                    case .memory: memorySections
                    }
                }
                if let error = service.lastError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            .padding(Theme.spacing.page)
        }
    }

    // MARK: - 统计瓦片（总量 + 各 CLI 计数，点击即筛选；等宽均分）

    private var statsTiles: some View {
        HStack(spacing: 8) {
            StatTile(
                value: "\(totalCount)",
                label: mode == .skills ? "全部技能" : "全部记忆",
                icon: mode == .skills ? "wand.and.stars" : "brain.fill",
                tint: Theme.brand,
                isSelected: selectedSource == nil
            ) { selectedSource = nil }
            ForEach(availableSources, id: \.self) { source in
                StatTile(
                    value: "\(count(for: source))",
                    label: source.displayName, source: source,
                    tint: Theme.brand,
                    isSelected: selectedSource == source
                ) { selectedSource = source }
            }
        }
    }

    private var totalCount: Int {
        mode == .skills ? service.skills.count : service.memories.count
    }

    /// 有数据的来源（allCases 顺序）；瓦片与分区都按此渲染
    private var availableSources: [AgentSource] {
        AgentSource.allCases.filter { count(for: $0) > 0 }
    }

    private func count(for source: AgentSource) -> Int {
        mode == .skills
            ? service.skills(for: source).count
            : service.memories(for: source).count
    }

    /// 当前筛选下要展示的来源分区
    private var visibleSources: [AgentSource] {
        if let selected = selectedSource {
            return count(for: selected) > 0 ? [selected] : []
        }
        return availableSources
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.scanning {
            VStack(spacing: 8) {
                ProgressView()
                Text("正在扫描…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: mode == .skills ? "wand.and.stars" : "brain.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.brand.opacity(0.5))
                Text(service.isSearching
                    ? "没有匹配项"
                    : (mode == .skills ? "还没有技能" : "还没有记忆"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if !service.isSearching {
                    Text("点右上角 + 新建各 CLI 的" + (mode == .skills ? "技能" : "记忆"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Top 技能分析卡（时间档 + 排行，风格同用量页）

    /// 当前排行时间区间：固定档 = (startDate, now)；自定义 = (起当天零点, 止当天末)，自动纠正颠倒
    private func rankingRange() -> (from: Date, to: Date) {
        if period == .custom {
            let cal = Calendar.current
            let lo = min(customFrom, customTo)
            let hi = max(customFrom, customTo)
            let from = cal.startOfDay(for: lo)
            let to = cal.date(bySettingHour: 23, minute: 59, second: 59, of: hi) ?? hi
            return (from, to)
        }
        return (period.startDate, Date())
    }

    private func reloadRanking() {
        guard mode == .skills else { return }
        let range = rankingRange()
        usageService.loadSkillRanking(
            source: selectedSource, from: range.from, to: range.to)
    }

    private var topSkillsCard: some View {
        let rows = Array(usageService.skillRanking.prefix(10))
        let maxCount = rows.map(\.count).max() ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.brand)
                Text("Top 技能")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Picker("", selection: $period) {
                    ForEach(UsageService.DashboardPeriod.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                if period == .custom {
                    DatePicker("", selection: $customFrom, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                    Text("—").foregroundStyle(Color.secondary)
                    DatePicker("", selection: $customTo, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            if rows.isEmpty {
                Text("该时段暂无技能调用记录（调用数据来自 Claude transcript）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rankingRow(rank: index + 1, stat: row, maxCount: maxCount)
                    if index < rows.count - 1 {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.card)
                .strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    /// 排行行：名次 + 徽标 + 名称 + 比例条 + 最近活跃 + 次数；点击进内嵌详情
    private func rankingRow(
        rank: Int, stat: ToolCallsRepo.SkillUsageStat, maxCount: Int
    ) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                detail = SkillDetailTarget(
                    source: stat.source, name: stat.name,
                    entry: skillEntry(source: stat.source, name: stat.name))
            }
        } label: {
            HStack(spacing: 8) {
                Text("\(rank)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(rank <= 3
                        ? AnyShapeStyle(Theme.gold) : AnyShapeStyle(.tertiary))
                    .frame(width: 16, alignment: .trailing)
                SourceBadge(source: stat.source, size: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.name)
                        .font(.system(size: 11).monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [Theme.brand.opacity(0.55), Theme.brand],
                                    startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(3, proxy.size.width
                                    * CGFloat(stat.count) / CGFloat(max(1, maxCount))))
                        }
                    }
                    .frame(height: 4)
                }
                if let last = stat.lastTs {
                    Text(relativeFormatter.localizedString(for: last, relativeTo: Date()))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                Text("\(stat.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.brand)
                    .frame(width: 42, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Theme.spacing.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 把排行的统计名接回磁盘条目（详情可编辑）；best-effort 按来源 + 归一化名匹配
    private func skillEntry(source: AgentSource, name: String) -> SkillEntry? {
        let key = SkillMemoryService.normalizeSkillName(name)
        return service.skills.first {
            guard $0.source == source else { return false }
            let dir = URL(fileURLWithPath: $0.directory).lastPathComponent
            return SkillMemoryService.normalizeSkillName($0.name) == key
                || SkillMemoryService.normalizeSkillName(dir) == key
        }
    }

    // MARK: - 技能分区（每来源：分区头 + 卡片网格）

    @ViewBuilder
    private var skillsSections: some View {
        ForEach(visibleSources, id: \.self) { source in
            let items = sortedSkills(service.skills(for: source))
            sectionHeader(source: source, count: items.count)
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 10) {
                ForEach(items) { skill in
                    SkillCard(
                        skill: skill, service: service,
                        lastActive: skillStat(for: skill)?.lastTs,
                        onOpen: { openSkillDetail(skill) },
                        onDelete: { deleting = .skill(skill) })
                }
            }
        }
    }

    /// 系统级在前（projectName nil 排 ""），项目级按项目名归并，同组按名称
    private func sortedSkills(_ items: [SkillEntry]) -> [SkillEntry] {
        items.sorted {
            let l = $0.scope.projectName ?? ""
            let r = $1.scope.projectName ?? ""
            if l != r { return l < r }
            return $0.name.lowercased() < $1.name.lowercased()
        }
    }

    private func openSkillDetail(_ skill: SkillEntry) {
        withAnimation(.easeOut(duration: 0.15)) {
            detail = SkillDetailTarget(source: skill.source, name: skill.name, entry: skill)
        }
    }

    /// 归一化 "来源:名" → 技能统计（Claude 调用数据）；用于卡片"最近活跃"
    private var statsByKey: [String: ToolCallsRepo.SkillUsageStat] {
        var map: [String: ToolCallsRepo.SkillUsageStat] = [:]
        for stat in usageService.skillStats {
            map["\(stat.source.rawValue):\(SkillMemoryService.normalizeSkillName(stat.name))"] = stat
        }
        return map
    }

    private func skillStat(for skill: SkillEntry) -> ToolCallsRepo.SkillUsageStat? {
        let map = statsByKey
        let dir = URL(fileURLWithPath: skill.directory).lastPathComponent
        return map["\(skill.source.rawValue):\(SkillMemoryService.normalizeSkillName(skill.name))"]
            ?? map["\(skill.source.rawValue):\(SkillMemoryService.normalizeSkillName(dir))"]
    }

    // MARK: - 记忆分区

    @ViewBuilder
    private var memorySections: some View {
        ForEach(visibleSources, id: \.self) { source in
            let items = service.memories(for: source)
            sectionHeader(source: source, count: items.count)
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 10) {
                ForEach(items) { memory in
                    MemoryCard(
                        memory: memory, service: service,
                        onOpen: {
                            withAnimation(.easeOut(duration: 0.15)) { memoryDetail = memory }
                        },
                        onDelete: { deleting = .memory(memory) })
                }
            }
        }
    }

    /// 分区头：来源徽标 + 名称 + 计数 + 贯通分隔线（与计划页一致）
    private func sectionHeader(source: AgentSource, count: Int) -> some View {
        HStack(spacing: 7) {
            SourceBadge(source: source, size: 12)
            Text(source.displayName)
                .font(.system(size: 12, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10).monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Theme.brandFill(0.10)))
                .foregroundStyle(Theme.brand)
            VStack { Divider() }
        }
    }

    // MARK: - 动作

    private func startCreate(_ source: AgentSource, isSkill: Bool, _ label: String) {
        newName = ""
        creating = CreateTarget(source: source, isSkill: isSkill, label: label)
    }

    private var creatingBinding: Binding<Bool> {
        Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })
    }
    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}

// MARK: - 数据载体

private struct CreateTarget: Identifiable {
    let id = UUID()
    var source: AgentSource
    var isSkill: Bool
    var label: String
}

private enum DeleteTarget {
    case skill(SkillEntry)
    case memory(MemoryEntry)

    var title: String {
        switch self {
        case .skill(let s): return s.name
        case .memory(let m): return m.scope
        }
    }
    func perform(_ service: SkillMemoryService) {
        switch self {
        case .skill(let s): service.deleteSkill(s)
        case .memory(let m): service.deleteMemory(m)
        }
    }
}

// MARK: - 启停状态方块（技能卡片 / 技能详情共用）

/// 绿=启用 / 灰=停用，点击直接切换；带悬停提示
struct SkillStatusSquare: View {
    let enabled: Bool
    var size: CGFloat = 12
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(enabled ? Color.green.opacity(0.85) : Color.secondary.opacity(0.35))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(enabled ? "已启用（点击停用）" : "已停用（点击启用）")
    }
}

// MARK: - 卡片

/// 技能卡片：名称 + 描述 + meta（项目 chip · 最近活跃），右上角启停状态方块
private struct SkillCard: View {
    let skill: SkillEntry
    let service: SkillMemoryService
    let lastActive: Date?
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Text(skill.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(skill.enabled ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                SkillStatusSquare(enabled: skill.enabled) {
                    service.setSkillEnabled(skill, !skill.enabled)
                }
            }
            if let desc = skill.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                if let project = skill.scope.projectName {
                    Text(project)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.gold.opacity(0.15)))
                        .foregroundStyle(Theme.gold)
                        .lineLimit(1)
                }
                if let lastActive {
                    Text(relativeFormatter.localizedString(for: lastActive, relativeTo: Date()))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .help("最近调用时间")
                }
                Spacer(minLength: 0)
                if !skill.enabled {
                    Text("已停用")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .frame(height: 84)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .fill(Theme.surface)
                .opacity(skill.enabled ? 1 : 0.6))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .strokeBorder(
                    hovering ? Theme.brand.opacity(0.6) : Theme.hairline,
                    lineWidth: hovering ? 1 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: Theme.radius.container))
        .onTapGesture { onOpen() }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("查看详情") { onOpen() }
            Button(skill.enabled ? "停用" : "启用") {
                service.setSkillEnabled(skill, !skill.enabled)
            }
            Button("用默认编辑器打开") { service.openInEditor(path: skill.path) }
            Button("在 Finder 中显示") { service.reveal(path: skill.path) }
            Divider()
            Button("删除", role: .destructive) { onDelete() }
        }
    }
}

/// 记忆卡片：作用域名 + 文件名 + meta（修改时间 · 大小）；Codex 生成记忆带只读标
private struct MemoryCard: View {
    let memory: MemoryEntry
    let service: SkillMemoryService
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Text(memory.scope)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if memory.kind == .generated {
                    Text("只读")
                        .font(.system(size: 8.5, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(URL(fileURLWithPath: memory.path).lastPathComponent)
                .font(.system(size: 10).monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Text(memory.modifiedAt, formatter: relativeFormatter)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text(formatBytes(memory.sizeBytes))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(height: 76)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .fill(Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .strokeBorder(
                    hovering ? Theme.brand.opacity(0.6) : Theme.hairline,
                    lineWidth: hovering ? 1 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: Theme.radius.container))
        .onTapGesture { onOpen() }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(memory.isEditable ? "查看 / 编辑" : "查看") { onOpen() }
            if memory.isEditable {
                Button("用默认编辑器打开") { service.openInEditor(path: memory.path) }
            }
            Button("在 Finder 中显示") { service.reveal(path: memory.path) }
            if memory.isDeletable {
                Divider()
                Button("删除", role: .destructive) { onDelete() }
            }
        }
    }
}

// MARK: - 记忆内嵌详情（文档卡渲染 + 预览/编辑切换，与计划详情同排版）

private struct MemoryDetailView: View {
    let memory: MemoryEntry
    let service: SkillMemoryService
    let onBack: () -> Void
    let onDelete: () -> Void

    @State private var text: String
    @State private var editing = false
    @State private var saveNote: String?

    init(
        memory: MemoryEntry, service: SkillMemoryService,
        onBack: @escaping () -> Void, onDelete: @escaping () -> Void
    ) {
        self.memory = memory
        self.service = service
        self.onBack = onBack
        self.onDelete = onDelete
        // init 即加载：避免首帧空白（记忆均为小文件，主线程读取无感）
        _text = State(initialValue: service.readContent(path: memory.path) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if editing {
                TextEditor(text: $text)
                    .font(.system(size: 12).monospaced())
                    .padding(8)
            } else {
                ScrollView {
                    MarkdownRichText(text: text)
                        .padding(24)
                        .frame(maxWidth: 720, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radius.card)
                                .fill(Theme.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.radius.card)
                                        .strokeBorder(Theme.hairline, lineWidth: 0.5)))
                        .frame(maxWidth: .infinity)
                        .padding(Theme.spacing.page)
                }
            }
            Divider()
            footer
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("返回").font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            SourceBadge(source: memory.source, size: 12)
            Text(memory.scope)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if memory.isEditable {
                Picker("", selection: $editing) {
                    Text("预览").tag(false)
                    Text("编辑").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)
                Button { service.openInEditor(path: memory.path) } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("用默认编辑器打开")
            }
            Button { service.reveal(path: memory.path) } label: {
                Image(systemName: "folder").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
            if memory.isDeletable {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("移入废纸篓（可恢复）")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(memory.isEditable ? memory.path : "Codex 生成状态（只读） · \(memory.path)")
                .font(.system(size: 9).monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let note = saveNote {
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            if editing {
                Button("保存") {
                    service.save(path: memory.path, content: text) { ok in
                        saveNote = ok ? "已保存（写前留有备份）" : "保存失败"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveNote = nil }
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
