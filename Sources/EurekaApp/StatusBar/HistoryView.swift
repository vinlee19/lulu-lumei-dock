import Charts
import EurekaKit
import SwiftUI

/// Task history: last-14-days chart stacked by outcome + pinned "Running" group + a timeline in
/// four groups (Today / Yesterday / Earlier this week / Older). Per-turn records are merged into
/// one row per session — the data layer has one row per turn, and showing each turn looks like
/// duplicates; merged rows show session start time / total duration / total tokens (right stats
/// column), and multi-turn sessions get an "N turns" badge. Success green ✓ / failure red ✕ /
/// interrupted gray —, each with a text label. Supports "Recently active / Start time" sorting and
/// CSV export (export stays per turn, same semantics).
struct HistoryView: View {
    /// Per-turn history records (merged by session for display in this view)
    let tasks: [FinishedTask]
    /// Counts by (day, outcome) for the last 14 days (stacked chart; days without tasks are absent,
    /// zero-filled here)
    var dailyOutcomes: [(day: Date, outcome: TaskOutcome, count: Int)] = []
    /// sessionId → total tokens (right stats column; shows an em dash when there are no records)
    var tokens: [String: Int] = [:]
    /// Running tasks (pinned group; icon becomes a looping arrow + brand color)
    var runningTasks: [AgentTask] = []
    /// Session → most recent terminal, keyed by `AgentTask.key(source:sessionId:)`. A plain
    /// dictionary rather than a service: this view depends only on EurekaKit + SwiftUI and must not
    /// depend back on the service layer.
    var terminals: [String: TerminalBinding] = [:]
    /// CSV export (with a confirmation dialog, triggered by this view); the caller injects how the
    /// export result is shown
    var onExport: () -> Void = {}
    var exportMessage: String?
    /// Opens a session on the Sessions tab by id (nil = rows are not clickable). Injected rather
    /// than posted from here so this view stays free of app-level routing.
    var onOpenSession: ((String) -> Void)?
    @ObservedObject var settings: AppSettings

    @State private var showExportConfirm = false

    /// rawValue is the persisted token; label is the UI copy
    enum SortMode: String, CaseIterable {
        case active
        case start
        var label: String {
            self == .active
                ? L10n.text("Recently active", zhHans: "最近活跃")
                : L10n.text("Start time", zhHans: "开始时间")
        }
    }

    private var sortMode: SortMode {
        SortMode(rawValue: settings.historySortMode) ?? .active
    }

    /// Merge per-turn records by session (one row per turn for the same sessionId, which looks like
    /// duplicates)
    private var mergedSessions: [MergedSessionTask] {
        HistoryGrouping.mergeSessions(tasks)
    }

    /// Client-side sort (negligible cost within 200 rows): active = latest turn's finishedAt, start
    /// = session's first start time
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

    /// Group key (the date matching the current sort basis)
    private func groupKey(_ task: MergedSessionTask) -> Date {
        sortMode == .active ? task.finishedAt : startKey(task)
    }

    /// Header count: merged sessions without harness background calls, so it matches the
    /// per-day group counts and the sidebar badge.
    private var userSessionCount: Int {
        mergedSessions.filter { !PromptClassifier.isHarnessUtility($0.title ?? "") }.count
    }

    private enum HistoryLine: Identifiable {
        case session(MergedSessionTask)
        case utilities(Int)

        var id: String {
            switch self {
            case .session(let task): return task.id
            case .utilities: return "harness-utilities"
            }
        }
    }

    /// Folds a day's harness background calls into one row, placed where the first one was;
    /// user sessions keep their order. `userCount` feeds the day header.
    private func historyLines(
        _ tasks: [MergedSessionTask]
    ) -> (rows: [HistoryLine], userCount: Int) {
        let isUtility = { (task: MergedSessionTask) in
            PromptClassifier.isHarnessUtility(task.title ?? "")
        }
        let utilityCount = tasks.filter(isUtility).count
        var rows: [HistoryLine] = []
        var folded = false
        for task in tasks {
            if !isUtility(task) {
                rows.append(.session(task))
            } else if !folded {
                rows.append(.utilities(utilityCount))
                folded = true
            }
        }
        return (rows, tasks.count - utilityCount)
    }

    /// Four groups: Today / Yesterday / Earlier this week / Older (sortedTasks is already
    /// descending; keep that order within groups). Running sessions are already shown in the pinned
    /// group and must be excluded here: AgentTask.id and MergedSessionTask.id are both
    /// `source:sessionId`, and when the same id appears in two ForEach blocks within one
    /// LazyVStack, SwiftUI renders the latter as a hole that takes space but shows nothing — in the
    /// history list a big blank stretch within a group (same cause as the duplicate-path grid holes
    /// in AgentDefinitionIndexer).
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
            EmptyStateView(
                icon: "tray",
                title: L10n.text("No task history yet", zhHans: "还没有任务记录"),
                hint: L10n.text("Try a claude / codex / grok task", zhHans: "跑一次 claude / codex / grok 任务试试"))
                .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                header

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        chartCard
                            .padding(.horizontal, 12)
                            .padding(.top, 10)

                        // Running group (pinned; reuses the HistoryRow style with running-state
                        // icon / color / label)
                        if !runningTasks.isEmpty {
                            groupHeader(title: L10n.text("Running", zhHans: "运行中"), count: runningTasks.count)
                            ForEach(runningTasks) { task in
                                RunningRow(
                                    task: task,
                                    terminal: terminals[AgentTask.key(
                                        source: task.source, sessionId: task.sessionId)])
                                    .openableSessionRow(onOpenSession.map { open in { open(task.sessionId) } })
                                Divider().padding(.leading, 44).opacity(0.5)
                            }
                        }

                        ForEach(dayGroups, id: \.group) { entry in
                            let lines = historyLines(entry.tasks)
                            groupHeader(title: entry.group.label, count: lines.userCount)
                            ForEach(lines.rows) { row in
                                switch row {
                                case .session(let task):
                                    HistoryRow(
                                        task: task,
                                        tokens: tokens[task.sessionId],
                                        terminal: terminals[AgentTask.key(
                                            source: task.source, sessionId: task.sessionId)])
                                        .openableSessionRow(onOpenSession.map { open in { open(task.sessionId) } })
                                case .utilities(let count):
                                    HarnessUtilityRow(
                                        count: count,
                                        subtitle: L10n.text(
                                            "Internal prompts such as memory compaction and branch naming, not sessions you started",
                                            zhHans: "记忆压缩、分支名生成这类内部提示，不是你发起的会话"),
                                        verticalPadding: Theme.spacing.row)
                                }
                                Divider().padding(.leading, 44).opacity(0.5)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .confirmationDialog(
                L10n.text("Export the last 14 days of task history as CSV to Downloads?", zhHans: "导出近 14 天任务历史为 CSV 到下载目录？"),
                isPresented: $showExportConfirm, titleVisibility: .visible
            ) {
                Button(L10n.text("Export", zhHans: "导出")) { onExport() }
                Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) {}
            }
        }
    }

    // MARK: - Top bar (title + cross-source / count + sort capsule + export)

    private var header: some View {
        HStack(spacing: 8) {
            Text(L10n.text("Task history", zhHans: "任务历史"))
                .font(Theme.font.themed(15, .bold))
            Text(L10n.format("Across %@ sources · %@ sessions", zhHans: "跨 %@ 个来源 · 共 %@ 个会话", "\(Set(tasks.map(\.source)).count)", "\(userSessionCount)"))
                .font(Theme.font.themed(11))
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
            CardActionButton(icon: "square.and.arrow.up", help: L10n.text("Export the last 14 days as CSV", zhHans: "导出近 14 天历史为 CSV")) {
                showExportConfirm = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Task volume over the last 14 days (stacked by outcome)

    /// Chart data point (zero days still get a point: the x domain is fixed at 14 days, days
    /// without data get zero-height bars)
    private struct ChartPoint: Identifiable {
        var id: String { "\(day.timeIntervalSince1970)-\(outcome.rawValue)" }
        var day: Date
        var outcome: TaskOutcome
        var count: Int
    }

    /// Full zero-filled points for 14 days × three outcomes (stacked bars skip zero-height
    /// segments, but the axis domain stays stable) + the 14-day date sequence
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
                        Text(L10n.text("Tasks over the last 14 days", zhHans: "近 14 天任务量"))
                            .font(Theme.font.themed(12, .semibold))
                        Text(L10n.text("Stacked by outcome", zhHans: "按结局堆叠"))
                            .font(Theme.font.caption)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        // Legend totals: success N / failure N / interrupted N (omit zero-count outcomes)
                        ForEach(TaskOutcome.allCases, id: \.self) { outcome in
                            let count = series.points.filter { $0.outcome == outcome }
                                .reduce(0) { $0 + $1.count }
                            if count > 0 {
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
                    }
                    Chart(series.points) { point in
                        BarMark(
                            x: .value(L10n.text("Time", zhHans: "时间"), point.day, unit: .day),
                            y: .value(L10n.text("Tasks", zhHans: "任务数"), point.count))
                        .foregroundStyle(by: .value(L10n.text("Outcome", zhHans: "结局"), point.outcome.label))
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
                    .chartLegend(.hidden)  // The legend is drawn manually at the top right (with totals)
                    .frame(height: 120)
                }
            }
        }
    }

    /// Group header (label + count)
    private func groupHeader(title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Text("\(count)")
                .font(Theme.font.themedMono(9))
                .foregroundStyle(.quaternary)
        }
        .font(Theme.font.themed(10, .semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

// MARK: - Running row

/// Running task row: same style as HistoryRow, icon becomes a looping arrow + brand color +
/// "Running" label; the right stats column shows start time + elapsed time (unfinished tasks have
/// no token figure, so no placeholder).
private struct RunningRow: View {
    let task: AgentTask
    var terminal: TerminalBinding?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(Theme.font.themed(13))
                .foregroundStyle(Theme.brand)
                .frame(width: 16)
                .padding(.top, 1)

            SourceBadge(source: task.source, size: 13)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(task.title ?? task.projectName ?? task.sessionId)
                        .font(Theme.font.themed(12, .medium))
                        .lineLimit(2)
                    Text(L10n.text("Running", zhHans: "运行中"))
                        .font(Theme.font.themed(9.5, .medium))
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
                .font(Theme.font.themed(10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            // Right stats column: start time (emphasized) + elapsed time
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatStartTime(task.startedAt))
                    .font(Theme.font.themed(12, .semibold))
                    .foregroundStyle(.primary)
                Text(L10n.format(
                    "Running for %@",
                    zhHans: "已运行 %@",
                    formatDuration(Date().timeIntervalSince(task.startedAt))))
                    .font(Theme.font.themedMono(11))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, Theme.spacing.row)
    }
}

// MARK: - Clickable row

/// Hover highlight + click-to-open for a history / running row, the same affordance as the
/// knowledge list rows (`KnowledgeRow`). Without an action the row stays static.
private struct OpenableSessionRow: ViewModifier {
    let onOpen: (() -> Void)?
    @State private var hovering = false

    func body(content: Content) -> some View {
        if let onOpen {
            content
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(hovering ? Theme.brandFill(0.06) : Color.clear)
                        .padding(.horizontal, 4))
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
                .help(L10n.text("Open this session", zhHans: "打开这个会话"))
        } else {
            content
        }
    }
}

private extension View {
    func openableSessionRow(_ onOpen: (() -> Void)?) -> some View {
        modifier(OpenableSessionRow(onOpen: onOpen))
    }
}

// MARK: - History row

/// History row: one row = one session (per-turn records merged). Left: title + project / relative
/// end time; right stats column emphasizes session start time (large font), total duration, total
/// tokens; multi-turn sessions get an "N turns" badge.
private struct HistoryRow: View {
    let task: MergedSessionTask
    /// Session total tokens (nil shows an em dash)
    var tokens: Int?
    var terminal: TerminalBinding?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Status circle: success green ✓ / failure red ✕ / interrupted gray —
            Image(systemName: iconName)
                .font(Theme.font.themed(13))
                .foregroundStyle(iconColor)
                .frame(width: 16)
                .padding(.top, 1)

            SourceBadge(source: task.source, size: 13)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(task.title ?? task.projectName ?? task.sessionId)
                        .font(Theme.font.themed(12, .medium))
                        .lineLimit(2)
                    // Outcome text label (icon color alone isn't distinguishable at a glance, so
                    // add text)
                    Text(task.outcome.label)
                        .font(Theme.font.themed(9.5, .medium))
                        .foregroundStyle(iconColor)
                    if task.turnCount > 1 {
                        Text(L10n.format("%@ turns", zhHans: "%@ 轮", String(task.turnCount)))
                            .font(Theme.font.themed(9.5, .medium))
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
                .font(Theme.font.themed(10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                // Colored annotation for failure red / interrupted gray
                if let detail = task.detail, task.outcome != .success {
                    Text(detail)
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(task.outcome == .error
                            ? Theme.failureRed : Theme.autoCleanGray)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            // Right stats column: start time (emphasized) + compact duration · tokens line
            VStack(alignment: .trailing, spacing: 2) {
                if let start = task.sessionStartedAt {
                    Text(formatStartTime(start))
                        .font(Theme.font.themed(12, .semibold))
                        .foregroundStyle(.primary)
                }
                HStack(spacing: 4) {
                    if let duration = task.totalDuration {
                        Text(formatDuration(duration))
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text("\(tokens.map(formatTokens) ?? "—") tok")
                }
                .font(Theme.font.themedMono(10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
