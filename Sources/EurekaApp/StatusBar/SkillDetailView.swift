import Charts
import EurekaIngest
import EurekaKit
import EurekaStore
import SwiftUI

/// 技能详情页目标：可从技能条目进入（entry 有值，可编辑/显示描述），
/// 也可从纯统计行进入（entry 为 nil，只读少量信息）。
struct SkillDetailTarget: Identifiable {
    var source: AgentSource
    var name: String
    var entry: SkillEntry?
    var id: String { "\(source.rawValue):\(name)" }
}

/// 技能详情页：基本描述 + 跨工具配置矩阵（logo）+ 调用统计（次数 / 触发时 token / 按天趋势）。
/// 调用数据仅 Claude 可得（transcript 记 Skill 调用）；其它来源显示"无逐技能调用数据"。
struct SkillDetailView: View {
    let target: SkillDetailTarget
    @ObservedObject var service: SkillMemoryService
    @ObservedObject var usageService: UsageService

    @Environment(\.dismiss) private var dismiss
    @State private var series: [UsageService.SkillDayCount] = []
    @State private var editor: EditorTarget?

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
            headerBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    descriptionSection
                    matrixSection
                    statsSection
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 520, height: 460)
        .onAppear(perform: loadSeries)
        .sheet(item: $editor) { EditorSheet(service: service, target: $0) }
    }

    // MARK: - 顶部

    private var headerBar: some View {
        HStack(spacing: 8) {
            SourceBadge(source: target.source, size: 16)
            Text(target.entry?.name ?? target.name)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let entry = target.entry {
                Button { service.reveal(path: entry.path) } label: {
                    Image(systemName: "folder")
                }
                .help("在 Finder 中显示")
                Button {
                    editor = EditorTarget(
                        id: entry.path, title: entry.name, path: entry.path, isSkill: true)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("编辑")
            }
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .help("关闭")
        }
        .buttonStyle(.borderless)
        .padding(10)
    }

    // MARK: - 描述

    @ViewBuilder
    private var descriptionSection: some View {
        if let desc = target.entry?.description, !desc.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("描述")
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 跨工具配置矩阵

    private var matrixSection: some View {
        let configs = service.configurations(forName: target.name)
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("配置于")
            HStack(alignment: .top, spacing: 16) {
                ForEach(AgentSource.allCases, id: \.self) { source in
                    let origin = configs[source]
                    VStack(spacing: 4) {
                        SourceBadge(source: source, size: 22)
                            .opacity(origin == nil ? 0.2 : 1)
                        Text(source.displayName)
                            .font(.system(size: 9))
                            .foregroundStyle(origin == nil ? .tertiary : .secondary)
                        Text(originLabel(origin))
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(originColor(origin))
                    }
                    .frame(minWidth: 52)
                }
                Spacer(minLength: 0)
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
                HStack(alignment: .top, spacing: 18) {
                    metric("累计调用", "\(stat.count) 次")
                    if target.source == .claude {
                        metric("触发时 token", formatTokens(stat.tokens))
                    }
                    if let last = stat.lastTs {
                        metric("最近活跃",
                            relativeFormatter.localizedString(for: last, relativeTo: Date()))
                    }
                    Spacer(minLength: 0)
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
                    .foregroundStyle(target.source.brandColor)
                }
                .frame(height: 120)
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            }
        }
    }

    // MARK: - helpers

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

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
        }
    }
}

/// 技能使用分析：最近使用 / 最常使用 / 最久未使用 三个排行。
/// 排行数据源 = Claude transcript 的技能调用（其它来源暂无逐技能调用记录）。
struct SkillAnalyticsView: View {
    @ObservedObject var service: SkillMemoryService
    @ObservedObject var usageService: UsageService
    let openDetail: (SkillDetailTarget) -> Void

    /// 排行展示行
    struct Row: Identifiable {
        var id: String
        var source: AgentSource
        var name: String
        var entry: SkillEntry?
        var count: Int
        var lastTs: Date?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if usageService.skillStats.isEmpty && longestUnused.isEmpty {
                    emptyState
                } else {
                    section("最近使用", rows: recentlyUsed)
                    section("最常使用", rows: mostUsed)
                    section("最久未使用", rows: longestUnused)
                }
                Text("调用数据来自 Claude transcript；其它来源暂无逐技能调用记录。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(12)
            }
        }
    }

    // MARK: - 排行计算

    private var recentlyUsed: [Row] {
        usageService.skillStats
            .filter { $0.lastTs != nil }
            .sorted { ($0.lastTs ?? .distantPast) > ($1.lastTs ?? .distantPast) }
            .prefix(10)
            .map { stat in
                Row(id: "recent-\(stat.id)", source: stat.source, name: stat.name,
                    entry: entry(source: stat.source, name: stat.name),
                    count: stat.count, lastTs: stat.lastTs)
            }
    }

    private var mostUsed: [Row] {
        usageService.skillStats
            .sorted { $0.count > $1.count }
            .prefix(10)
            .map { stat in
                Row(id: "most-\(stat.id)", source: stat.source, name: stat.name,
                    entry: entry(source: stat.source, name: stat.name),
                    count: stat.count, lastTs: stat.lastTs)
            }
    }

    /// 最久未使用：仅 Claude 用户技能可判定（其余来源无逐技能调用数据）。
    /// 从未使用（无统计）排最前，其后按最近活跃升序（越久越前）。
    private var longestUnused: [Row] {
        var statByName: [String: ToolCallsRepo.SkillUsageStat] = [:]
        for stat in usageService.skillStats where stat.source == .claude {
            statByName[SkillMemoryService.normalizeSkillName(stat.name)] = stat
        }
        let rows = service.skills
            .filter { $0.source == .claude }
            .map { skill -> Row in
                let dir = URL(fileURLWithPath: skill.directory).lastPathComponent
                let stat = statByName[SkillMemoryService.normalizeSkillName(skill.name)]
                    ?? statByName[SkillMemoryService.normalizeSkillName(dir)]
                return Row(id: "unused-\(skill.id)", source: .claude, name: skill.name,
                    entry: skill, count: stat?.count ?? 0, lastTs: stat?.lastTs)
            }
        return Array(rows.sorted { lhs, rhs in
            switch (lhs.lastTs, rhs.lastTs) {
            case (nil, nil): return lhs.name.lowercased() < rhs.name.lowercased()
            case (nil, _): return true
            case (_, nil): return false
            case let (l?, r?): return l < r
            }
        }.prefix(10))
    }

    /// 把统计行接回磁盘条目（描述/详情/编辑）；best-effort 按来源 + 归一化名
    private func entry(source: AgentSource, name: String) -> SkillEntry? {
        let key = SkillMemoryService.normalizeSkillName(name)
        return service.skills.first {
            guard $0.source == source else { return false }
            let dir = URL(fileURLWithPath: $0.directory).lastPathComponent
            return SkillMemoryService.normalizeSkillName($0.name) == key
                || SkillMemoryService.normalizeSkillName(dir) == key
        }
    }

    // MARK: - 视图

    @ViewBuilder
    private func section(_ title: String, rows: [Row]) -> some View {
        if !rows.isEmpty {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ForEach(rows) { row in
                analyticsRow(row)
                Divider().opacity(0.3)
            }
        }
    }

    private func analyticsRow(_ row: Row) -> some View {
        Button {
            openDetail(SkillDetailTarget(source: row.source, name: row.name, entry: row.entry))
        } label: {
            HStack(spacing: 8) {
                SourceBadge(source: row.source, size: 12)
                Text(row.entry?.name ?? row.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.entry == nil {
                    Text("外部")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Spacer(minLength: 6)
                Text(row.lastTs.map {
                    relativeFormatter.localizedString(for: $0, relativeTo: Date())
                } ?? "从未使用")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Text("\(row.count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.skills)
                    .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 26))
                .foregroundStyle(Theme.skills.opacity(0.4))
            Text("暂无技能调用数据")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
