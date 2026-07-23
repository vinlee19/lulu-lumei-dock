import Charts
import EurekaIngest
import EurekaKit
import EurekaStore
import SwiftUI

/// 技能详情页目标：可从技能卡片进入（entry 有值，可编辑/显示描述），
/// 也可从纯统计行进入（entry 为 nil，只读少量信息）。
struct SkillDetailTarget: Identifiable {
    var source: AgentSource
    var name: String
    var entry: SkillEntry?
    var id: String { "\(source.rawValue):\(name)" }
}

/// 技能内嵌详情页（列表页内滑入，非弹窗）：
/// 概览 = 描述 + 跨工具配置矩阵 + 调用统计；预览/编辑 = SKILL.md 文档渲染与改写。
/// 调用数据仅 Claude 可得（transcript 记 Skill 调用）；其它来源显示"无逐技能调用数据"。
struct SkillDetailView: View {
    let target: SkillDetailTarget
    @ObservedObject var service: SkillMemoryService
    @ObservedObject var usageService: UsageService
    let onBack: () -> Void
    let onDelete: (SkillEntry) -> Void

    /// 详情分段：概览（统计矩阵）/ 预览（SKILL.md 渲染）/ 编辑（原文）
    enum Pane: String, CaseIterable { case overview = "概览", preview = "预览", edit = "编辑" }
    @State private var pane: Pane = .overview
    @State private var series: [UsageService.SkillDayCount] = []
    @State private var text = ""
    @State private var textLoaded = false
    @State private var saveNote: String?

    /// 本周排名（金块；nil = 本周无调用）
    @State private var weeklyRank: Int?

    /// 实时条目：启停会移动技能目录（路径变化），从 service 按
    /// 来源 + 项目 + 目录名回查最新条目，保证开关/编辑始终作用于当前路径。
    private var entry: SkillEntry? {
        guard let base = target.entry else { return nil }
        let dir = URL(fileURLWithPath: base.directory).lastPathComponent
        return service.skills.first {
            $0.source == base.source
                && $0.scope.projectName == base.scope.projectName
                && URL(fileURLWithPath: $0.directory).lastPathComponent == dir
        } ?? base
    }

    /// 匹配到的调用统计（按来源 + 归一化名）
    private var stat: ToolCallsRepo.SkillUsageStat? {
        let key = SkillMemoryService.normalizeSkillName(target.name)
        return usageService.skillStats.first {
            $0.source == target.source
                && SkillMemoryService.normalizeSkillName($0.name) == key
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            switch pane {
            case .overview:
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        descriptionSection
                        matrixSection
                        statsSection
                    }
                    .padding(Theme.spacing.page)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .preview:
                MarkdownDocumentCard(text: text)
            case .edit:
                TextEditor(text: $text)
                    .font(.system(size: 12).monospaced())
                    .padding(8)
            }
            if pane != .overview, let entry {
                Divider()
                documentFooter(entry)
            }
        }
        .onAppear {
            loadSeries()
            loadText()
            usageService.loadSkillWeeklyRank(
                source: target.source, name: stat?.name ?? target.name
            ) { weeklyRank = $0 }
        }
    }

    // MARK: - 顶部工具栏（返回 + 标题 + 启停方块 + 分段）

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("返回").font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            SourceLogoTile(source: target.source, size: 26)
            Text(entry?.name ?? target.name)
                .font(Theme.font.monoSkillName(15, weight: .bold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let project = entry?.scope.projectName {
                TagChip(project)
            }
            if let entry {
                EnableToggle(enabled: entry.enabled) {
                    service.setSkillEnabled(entry, !entry.enabled)
                }
            }
            Spacer(minLength: 8)
            if let entry {
                // 分段「概览 / 预览 / 编辑」：选中紫底白字
                CapsuleTabTray {
                    ForEach(Pane.allCases, id: \.self) { item in
                        CapsuleTabButton(
                            title: item.rawValue,
                            fillWidth: false,
                            isSelected: pane == item
                        ) { pane = item }
                    }
                }
                Button { service.openInEditor(path: entry.path) } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("用默认编辑器打开")
                Button { service.reveal(path: entry.path) } label: {
                    Image(systemName: "folder").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")
                Button(role: .destructive) { onDelete(entry) } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("移入废纸篓（可恢复）")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func documentFooter(_ entry: SkillEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.path)
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
            if pane == .edit {
                Button("保存") {
                    service.save(path: entry.path, content: text) { ok in
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

    // MARK: - 描述

    @ViewBuilder
    private var descriptionSection: some View {
        if let desc = entry?.description, !desc.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("描述")
                Text(desc)
                    .font(.system(size: 13.5))
                    .lineSpacing(6)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 跨工具配置矩阵

    private var matrixSection: some View {
        let configs = service.configurations(forName: target.name)
        let configured = AgentSource.allCases.filter { configs[$0] != nil }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionTitle("配置于")
                Text("\(AgentSource.allCases.count) 个工具中 \(configured) 个可用")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(AgentSource.allCases, id: \.self) { source in
                    let origin = configs[source]
                    VStack(spacing: 4) {
                        SourceBadge(source: source, size: 22)
                            .opacity(origin == nil ? 0.28 : 1)
                        Text(source.displayName)
                            .font(.system(size: 9))
                            .foregroundStyle(origin == nil ? .tertiary : .secondary)
                        Text(originLabel(origin))
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(originColor(origin))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    // 已配置 = 紫描边紫浅底；未配置 = 灰边
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.container)
                            .fill(origin != nil ? Theme.brandFill(0.08) : Theme.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.container)
                            .strokeBorder(
                                origin != nil ? Theme.brand.opacity(0.5) : Theme.cardBorder,
                                lineWidth: origin != nil ? 1 : 0.5))
                }
            }
        }
    }

    private func originLabel(_ origin: SkillOrigin?) -> String {
        switch origin {
        case .user: return "自建"
        case .bundled: return "内置"
        case nil: return "未配置"
        }
    }

    private func originColor(_ origin: SkillOrigin?) -> Color {
        switch origin {
        case .user: return .green
        case .bundled: return .blue
        case nil: return .secondary
        }
    }

    // MARK: - 调用统计

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("调用统计")
            if let stat {
                HStack(spacing: 8) {
                    metricTile("累计调用", "\(stat.count) 次", valueColor: Theme.brand)
                    if target.source == .claude {
                        metricTile("触发时 token", formatTokens(stat.tokens))
                    }
                    if let last = stat.lastTs {
                        metricTile("最近活跃",
                            relativeFormatter.localizedString(for: last, relativeTo: Date()))
                    }
                    if let weeklyRank {
                        metricTile("本周排名", "#\(weeklyRank)", gold: true)
                    }
                }
                if target.source == .claude {
                    Text("触发时 token ≈ 调用当轮上下文规模，非技能整段执行开销")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                trendChart
            } else {
                Text(target.source == .claude
                    ? "近期暂无调用记录"
                    : "该来源无逐技能调用数据（仅 Claude 可统计）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder
    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("近 30 天调用")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            if series.isEmpty {
                Text("近 30 天无调用")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart(series) { point in
                    BarMark(
                        x: .value("日期", point.day, unit: .day),
                        y: .value("调用", point.count))
                    // 全局紫金：图表柱不用 CLI 品牌色
                    .foregroundStyle(Theme.chartBarGradient)
                }
                .frame(height: 120)
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            }
        }
    }

    // MARK: - helpers

    private func loadText() {
        guard !textLoaded, let entry else { return }
        text = service.readContent(path: entry.path) ?? ""
        textLoaded = true
    }

    private func loadSeries() {
        let to = Date()
        let from = Calendar.current.date(byAdding: .day, value: -30, to: to) ?? to
        // 序列按 tool_calls 里存的原始调用名查询（stat.name 精确；退回 target.name）
        let queryName = stat?.name ?? target.name
        usageService.loadSkillDailySeries(
            source: target.source, name: queryName, from: from, to: to
        ) { points in
            series = points
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func metricTile(
        _ label: String, _ value: String,
        valueColor: Color = .primary, gold: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(gold ? Theme.gold.opacity(0.9) : Color.primary.opacity(0.35))
            Text(value)
                .font(Theme.font.statNumber(18))
                .foregroundStyle(gold ? Theme.gold : valueColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // 本周排名 = 金块；其余 = 白底细描边
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .fill(gold ? Theme.gold.opacity(0.12) : Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .strokeBorder(gold ? Theme.gold.opacity(0.4) : Theme.cardBorder,
                              lineWidth: 0.5))
    }
}
