import Charts
import EurekaKit
import SwiftUI

/// 任务历史：近 14 天按结局堆叠图 + 置顶「运行中」分组 + 四档分组时间线
/// （今天/昨天/本周更早/更早）。逐轮（turn）记录按会话合并为一行——数据层每轮一条，
/// 逐轮展示像重复；合并后显会话开始时间/时长合计/Tokens 总量（右侧统计栏），
/// 多轮会话带「N 轮」角标。成功绿圈✓ / 失败红圈✕ / 中断灰圈—，旁带文字标签。
/// 支持「最近活跃 / 开始时间」排序与 CSV 导出（导出仍逐轮，口径不变）。
struct HistoryView: View {
    /// 逐轮历史记录（视图内按会话合并展示）
    let tasks: [FinishedTask]
    /// 近 14 天按 (天, 结局) 计数（堆叠图；无任务日不出现，这里补 0）
    var dailyOutcomes: [(day: Date, outcome: TaskOutcome, count: Int)] = []
    /// sessionId → token 总量（右侧统计栏；无记录显「—」）
    var tokens: [String: Int] = [:]
    /// 运行中任务（置顶分组；图标换循环箭头 + 品牌色）
    var runningTasks: [AgentTask] = []
    /// 会话 → 最近所在终端，键 `AgentTask.key(source:sessionId:)`。
    /// 传纯字典而不是 service：本视图只依赖 EurekaKit + SwiftUI，不该反向依赖服务层。
    var terminals: [String: TerminalBinding] = [:]
    /// 导出 CSV（含确认弹窗，由本视图触发）；导出结果提示由调用方注入展示
    var onExport: () -> Void = {}
    var exportMessage: String?
    @ObservedObject var settings: AppSettings

    @State private var showExportConfirm = false

    /// rawValue 为持久化 token；label 为界面文案
    enum SortMode: String, CaseIterable {
        case active
        case start
        var label: String { self == .active ? "最近活跃" : "开始时间" }
    }

    private var sortMode: SortMode {
        SortMode(rawValue: settings.historySortMode) ?? .active
    }

    /// 逐轮记录按会话合并（同 sessionId 每轮一条，逐轮展示像重复）
    private var mergedSessions: [MergedSessionTask] {
        HistoryGrouping.mergeSessions(tasks)
    }

    /// 客户端排序（200 行内成本可忽略）：活跃=最近一轮 finishedAt，开始=会话最初开始时间
    private var sortedTasks: [MergedSessionTask] {
        switch sortMode {
        case .active:
            return mergedSessions.sorted { $0.finishedAt > $1.finishedAt }
        case .start:
            return mergedSessions.sorted { startKey($0) > startKey($1) }
        }
    }

    private func startKey(_ task: MergedSessionTask) -> Date {
        task.sessionStartedAt ?? task.finishedAt
    }

    /// 分组键（跟随当前排序依据的日期）
    private func groupKey(_ task: MergedSessionTask) -> Date {
        sortMode == .active ? task.finishedAt : startKey(task)
    }

    /// 四档分组：今天 / 昨天 / 本周更早 / 更早（sortedTasks 已倒序，组内保持该顺序）。
    /// 运行中的会话已在置顶分组呈现，这里必须剔除：AgentTask.id 与 MergedSessionTask.id
    /// 同为 `source:sessionId`，同一 id 在同一个 LazyVStack 的两个 ForEach 里重复出现时，
    /// SwiftUI 会把后者渲染成只占位不显示的空洞——历史列表里表现为组内一大段空白
    /// （成因同 AgentDefinitionIndexer 的重复 path 网格空洞）。
    private var dayGroups: [(group: HistoryDayGroup, tasks: [MergedSessionTask])] {
        let runningKeys = Set(runningTasks.map(\.id))
        var buckets: [HistoryDayGroup: [MergedSessionTask]] = [:]
        for task in sortedTasks where !runningKeys.contains(task.id) {
            buckets[HistoryGrouping.group(of: groupKey(task), now: Date()), default: []]
                .append(task)
        }
        return HistoryDayGroup.allCases.compactMap { group in
            guard let tasks = buckets[group], !tasks.isEmpty else { return nil }
            return (group, tasks)
        }
    }

    var body: some View {
        if tasks.isEmpty && runningTasks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.brandFg.opacity(0.45))
                Text("还没有任务记录")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("跑一次 claude / codex / grok 任务试试")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                header

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        chartCard
                            .padding(.horizontal, 12)
                            .padding(.top, 10)

                        // 运行中分组（置顶；复用 HistoryRow 样式，图标/色/标签换运行中语义）
                        if !runningTasks.isEmpty {
                            groupHeader(title: "运行中", count: runningTasks.count)
                            ForEach(runningTasks) { task in
                                RunningRow(
                                    task: task,
                                    terminal: terminals[AgentTask.key(
                                        source: task.source, sessionId: task.sessionId)])
                                Divider().padding(.leading, 44).opacity(0.5)
                            }
                        }

                        ForEach(dayGroups, id: \.group) { entry in
                            groupHeader(title: entry.group.label, count: entry.tasks.count)
                            ForEach(entry.tasks) { task in
                                HistoryRow(
                                    task: task,
                                    tokens: tokens[task.sessionId],
                                    terminal: terminals[AgentTask.key(
                                        source: task.source, sessionId: task.sessionId)])
                                Divider().padding(.leading, 44).opacity(0.5)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .confirmationDialog(
                "导出近 14 天任务历史为 CSV 到下载目录？",
                isPresented: $showExportConfirm, titleVisibility: .visible
            ) {
                Button("导出") { onExport() }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: - 顶栏（标题 + 跨源/条数 + 排序胶囊 + 导出）

    private var header: some View {
        HStack(spacing: 8) {
            Text("任务历史")
                .font(Theme.font.pageTitle)
            Text("跨 \(Set(tasks.map(\.source)).count) 个来源 · 共 \(dayGroups.reduce(0) { $0 + $1.tasks.count }) 个会话")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            if let exportMessage {
                Text(exportMessage)
                    .font(Theme.font.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            CapsuleTabTray {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    CapsuleTabButton(
                        title: mode.label,
                        fillWidth: false,
                        isSelected: sortMode == mode
                    ) { settings.historySortMode = mode.rawValue }
                }
            }
            CardActionButton(icon: "square.and.arrow.up", help: "导出近 14 天历史为 CSV") {
                showExportConfirm = true
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 近 14 天任务量（按结局堆叠）

    /// 图表数据点（零值日也出点：x 域固定 14 天，缺数据的日柱子为 0 高）
    private struct ChartPoint: Identifiable {
        var id: String { "\(day.timeIntervalSince1970)-\(outcome.rawValue)" }
        var day: Date
        var outcome: TaskOutcome
        var count: Int
    }

    /// 补 0 后的 14 天 × 三结局全量点（堆叠柱不画 0 高段，但轴域稳定）+ 14 天日序列
    private var chartSeries: (points: [ChartPoint], days: [Date]) {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let days = (0..<14).compactMap {
            cal.date(byAdding: .day, value: -$0, to: todayStart)
        }.reversed()
        var lookup: [Date: [TaskOutcome: Int]] = [:]
        for entry in dailyOutcomes {
            lookup[cal.startOfDay(for: entry.day), default: [:]][entry.outcome, default: 0]
                += entry.count
        }
        let points = days.flatMap { day in
            TaskOutcome.allCases.map { outcome in
                ChartPoint(day: day, outcome: outcome, count: lookup[day]?[outcome] ?? 0)
            }
        }
        return (points, Array(days))
    }

    @ViewBuilder
    private var chartCard: some View {
        let series = chartSeries
        let total = series.points.reduce(0) { $0 + $1.count }
        if total > 0 {
            SectionCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("近 14 天任务量")
                            .font(Theme.font.themed(12, .semibold))
                        Text("按结局堆叠")
                            .font(Theme.font.caption)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        // 图例合计：成功 N / 失败 N / 中断 N
                        ForEach(TaskOutcome.allCases, id: \.self) { outcome in
                            let count = series.points.filter { $0.outcome == outcome }
                                .reduce(0) { $0 + $1.count }
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(Theme.outcomeColor(outcome))
                                    .frame(width: 6, height: 6)
                                Text("\(outcome.label) \(count)")
                                    .font(Theme.font.themedMono(9.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Chart(series.points) { point in
                        BarMark(
                            x: .value("时间", point.day, unit: .day),
                            y: .value("任务数", point.count))
                        .foregroundStyle(by: .value("结局", point.outcome.label))
                    }
                    .chartForegroundStyleScale(
                        domain: TaskOutcome.allCases.map(\.label),
                        range: TaskOutcome.allCases.map(Theme.outcomeColor))
                    .chartXScale(domain: series.days.first!...series.days.last!
                        .addingTimeInterval(86400))
                    .chartYAxis {
                        AxisMarks { _ in
                            AxisGridLine()
                            AxisValueLabel()
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                        }
                    }
                    .chartLegend(.hidden)  // 图例已自绘在右上（带合计数）
                    .frame(height: 120)
                }
            }
        }
    }

    /// 分组头（标签 + 条数）
    private func groupHeader(title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Text("\(count)")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.quaternary)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

// MARK: - 运行中行

/// 运行中任务行：样式与 HistoryRow 一致，图标换循环箭头 + 品牌色 +「运行中」标签；
/// 右侧统计栏显开始时间 + 已运行时长（未结束无 token 口径，不占位）。
private struct RunningRow: View {
    let task: AgentTask
    var terminal: TerminalBinding?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13))
                .foregroundStyle(Theme.brand)
                .frame(width: 16)
                .padding(.top, 1)

            SourceBadge(source: task.source, size: 13)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(task.title ?? task.projectName ?? task.sessionId)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                    Text("运行中")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.brandFg)
                }
                HStack(spacing: 4) {
                    if let project = task.projectName {
                        Text(project)
                        Text("·")
                    }
                    Text(relativeFormatter.localizedString(
                        for: task.lastActivityAt, relativeTo: Date()))
                    if let terminal {
                        Text("·")
                        TerminalBadge(
                            binding: terminal,
                            isRunning: TerminalActivator.isRunning(terminal))
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            // 右侧统计栏：开始时间（强调）+ 已运行时长
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatStartTime(task.startedAt))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("已运行 \(formatDuration(Date().timeIntervalSince(task.startedAt)))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, Theme.spacing.row)
    }
}

// MARK: - 历史行

/// 历史行：一行 = 一个会话（逐轮记录已合并）。左侧标题 + 项目/相对结束时间；
/// 右侧统计栏强调会话开始时间（大字号）、时长合计、Tokens 总量；多轮带「N 轮」角标。
private struct HistoryRow: View {
    let task: MergedSessionTask
    /// 会话 token 总量（nil 显「—」）
    var tokens: Int?
    var terminal: TerminalBinding?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 状态圆：成功绿圈✓ / 失败红圈✕ / 中断灰圈—
            Image(systemName: iconName)
                .font(.system(size: 13))
                .foregroundStyle(iconColor)
                .frame(width: 16)
                .padding(.top, 1)

            SourceBadge(source: task.source, size: 13)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(task.title ?? task.projectName ?? task.sessionId)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                    // 结局文字标签（图标色弱提示不够一眼可辨，补文字）
                    Text(task.outcome.label)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(iconColor)
                    if task.turnCount > 1 {
                        Text("\(task.turnCount) 轮")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 4) {
                    if let project = task.projectName {
                        Text(project)
                        Text("·")
                    }
                    Text(relativeFormatter.localizedString(
                        for: task.finishedAt, relativeTo: Date()))
                    if let terminal {
                        Text("·")
                        TerminalBadge(
                            binding: terminal,
                            isRunning: TerminalActivator.isRunning(terminal))
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                // 失败红 / 中断灰的彩色注释
                if let detail = task.detail, task.outcome != .success {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(task.outcome == .error
                            ? Theme.failureRed : Theme.autoCleanGray)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            // 右侧统计栏：开始时间（强调）+ 时长合计 + Tokens 总量
            VStack(alignment: .trailing, spacing: 2) {
                if let start = task.sessionStartedAt {
                    Text(formatStartTime(start))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                if let duration = task.totalDuration {
                    Text("时长 \(formatDuration(duration))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("Tokens \(tokens.map(formatTokens) ?? "—")")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, Theme.spacing.row)
    }

    private var iconName: String {
        switch task.outcome {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .interrupted: return "minus.circle.fill"
        }
    }

    private var iconColor: Color {
        Theme.outcomeColor(task.outcome)
    }
}
