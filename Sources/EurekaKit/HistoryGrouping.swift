import Foundation

/// 历史页按天分组：今天 / 昨天 / 本周更早 / 更早 四档。
/// 抽成纯函数（now/calendar 可注入）以便边界单测。
public enum HistoryDayGroup: String, CaseIterable, Sendable {
    case today
    case yesterday
    case earlierThisWeek
    case earlier

    public var label: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .earlierThisWeek: return "本周更早"
        case .earlier: return "更早"
        }
    }
}

public enum HistoryGrouping {
    /// 归档某一天。判据都按「日零点」比较，与当天具体时刻无关：
    /// 今天 = 与 now 同日；昨天 = now 前一日；本周更早 = 落在 now 所在周起点及之后；
    /// 其余 = 更早。未来的日期（时钟漂移）归入今天，与 isDateInToday 口径一致地宽容。
    public static func group(
        of date: Date, now: Date, calendar: Calendar = .current
    ) -> HistoryDayGroup {
        let dayStart = calendar.startOfDay(for: date)
        let nowStart = calendar.startOfDay(for: now)
        if dayStart >= nowStart { return .today }
        if let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: nowStart),
           dayStart >= yesterdayStart {
            return .yesterday
        }
        if let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
           dayStart >= weekStart {
            return .earlierThisWeek
        }
        return .earlier
    }
}

/// 按会话合并后的历史条目：同一会话的逐轮（turn）记录聚合为一行。
/// 数据层按轮次写入 `task_history`（同 sessionId 每轮一条），历史页逐轮展示像重复，
/// 故在 UI 层合并；表结构与 CSV 导出等其它消费方口径不变。
public struct MergedSessionTask: Equatable, Sendable, Identifiable {
    /// `source:sessionId`（ForEach 唯一键）
    public var id: String { "\(source.rawValue):\(sessionId)" }
    public var source: AgentSource
    public var sessionId: String
    public var title: String?
    public var cwd: String?
    /// 会话最初开始时间（各轮 `sessionStartedAt ?? startedAt` 的最早值）
    public var sessionStartedAt: Date?
    /// 最近一轮的结束时间（排序/分组/相对时间用）
    public var finishedAt: Date
    /// 最近一轮的结局
    public var outcome: TaskOutcome
    /// 最近一条非 success 轮的补充说明（全成功则 nil）
    public var detail: String?
    public var terminal: TerminalBinding?
    /// 合并的轮数（>1 时 UI 加「N 轮」角标）
    public var turnCount: Int
    /// 各轮时长合计（仅计入 startedAt 非 nil 的轮）
    public var totalDuration: TimeInterval?

    public var projectName: String? {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}

extension HistoryGrouping {
    /// 逐轮历史按 `(source, sessionId)` 合并为会话级条目。
    /// 返回顺序按各会话最近 `finishedAt` 倒序（View 层仍会按当前排序模式重排）。
    public static func mergeSessions(_ tasks: [FinishedTask]) -> [MergedSessionTask] {
        var order: [String] = []
        var groups: [String: [FinishedTask]] = [:]
        for task in tasks {
            let key = "\(task.source.rawValue):\(task.sessionId)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(task)
        }
        var merged = order.compactMap { key -> MergedSessionTask? in
            guard let turns = groups[key], let first = turns.first else { return nil }
            // 最近一轮 = finishedAt 最大者
            let latest = turns.max(by: { $0.finishedAt < $1.finishedAt }) ?? first
            let sessionStarted = turns.compactMap { $0.sessionStartedAt ?? $0.startedAt }.min()
            let durations = turns.compactMap(\.duration)
            // title/terminal 优先取最近一轮的非 nil 值，回退到任意一轮的非 nil 值
            let title = latest.title ?? turns.first(where: { $0.title != nil })?.title
            let terminal = latest.terminal ?? turns.first(where: { $0.terminal != nil })?.terminal
            // detail 取最近一条非 success 轮的说明
            let detail = turns.filter { $0.outcome != .success }
                .max(by: { $0.finishedAt < $1.finishedAt })?.detail
            return MergedSessionTask(
                source: first.source,
                sessionId: first.sessionId,
                title: title,
                cwd: latest.cwd ?? first.cwd,
                sessionStartedAt: sessionStarted,
                finishedAt: latest.finishedAt,
                outcome: latest.outcome,
                detail: detail,
                terminal: terminal,
                turnCount: turns.count,
                totalDuration: durations.isEmpty ? nil : durations.reduce(0, +)
            )
        }
        merged.sort { $0.finishedAt > $1.finishedAt }
        return merged
    }
}
