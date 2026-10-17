import Foundation

/// Day grouping on the history page: four buckets -- today / yesterday / earlier this week /
/// earlier. Extracted as a pure function (now/calendar injectable) for boundary unit tests.
public enum HistoryDayGroup: String, CaseIterable, Sendable {
    case today
    case yesterday
    case earlierThisWeek
    case earlier

    public var label: String {
        switch self {
        case .today: return L10n.text("Today", zhHans: "今天")
        case .yesterday: return L10n.text("Yesterday", zhHans: "昨天")
        case .earlierThisWeek: return L10n.text("Earlier this week", zhHans: "本周更早")
        case .earlier: return L10n.text("Earlier", zhHans: "更早")
        }
    }
}

public enum HistoryGrouping {
    /// Buckets a date. All comparisons use start-of-day, independent of the time of day:
    /// today = same day as now; yesterday = the day before now; earlier this week = on or
    /// after the start of now's week; everything else = earlier. Future dates (clock drift)
    /// go to today, as lenient as isDateInToday.
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

/// A history entry merged per session: one session's per-turn records aggregated into a row.
/// The data layer writes `task_history` per turn (one row per turn for the same sessionId),
/// which looks like duplicates on the history page, so merging happens in the UI layer; the
/// table schema and other consumers such as CSV export are unchanged.
public struct MergedSessionTask: Equatable, Sendable, Identifiable {
    /// `source:sessionId` (ForEach unique key)
    public var id: String { "\(source.rawValue):\(sessionId)" }
    public var source: AgentSource
    public var sessionId: String
    public var title: String?
    public var cwd: String?
    /// When the session first started (earliest `sessionStartedAt ?? startedAt` across turns)
    public var sessionStartedAt: Date?
    /// End time of the latest turn (used for sorting / grouping / relative time)
    public var finishedAt: Date
    /// Outcome of the latest turn
    public var outcome: TaskOutcome
    /// Detail of the latest non-success turn (nil if all succeeded)
    public var detail: String?
    public var terminal: TerminalBinding?
    /// Number of merged turns (> 1 shows an "N turns" badge in the UI)
    public var turnCount: Int
    /// Sum of turn durations (only turns with a non-nil startedAt count)
    public var totalDuration: TimeInterval?

    public var projectName: String? {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}

extension HistoryGrouping {
    /// Merges per-turn history into session-level entries by `(source, sessionId)`.
    /// Returned in descending order of each session's latest `finishedAt` (the view still
    /// re-sorts by the current sort mode).
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
            // Latest turn = the one with the largest finishedAt
            let latest = turns.max(by: { $0.finishedAt < $1.finishedAt }) ?? first
            let sessionStarted = turns.compactMap { $0.sessionStartedAt ?? $0.startedAt }.min()
            let durations = turns.compactMap(\.duration)
            // title/terminal prefer the latest turn's non-nil value, falling back to any
            // turn's non-nil value
            let title = latest.title ?? turns.first(where: { $0.title != nil })?.title
            let terminal = latest.terminal ?? turns.first(where: { $0.terminal != nil })?.terminal
            // detail comes from the latest non-success turn
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
