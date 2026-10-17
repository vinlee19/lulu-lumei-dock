import EurekaKit
import EurekaStore
import Foundation

/// Polls the `sessions` table of Hermes `state.db` to produce live events (Dynamic Island
/// lifecycle).
///
/// Why polling instead of installing a hook: Hermes shell hooks run synchronously on the agent's
/// main loop thread, and every command needs interactive user authorization — installing one
/// would add latency to every agent loop step and interrupt use, so this is an external read-only
/// poll instead (same trade-off as opencode / antigravity: with no callback, this is the only
/// live channel).
///
/// Progress watermark = `message_count + tool_call_count + api_call_count` + the sum of four
/// token kinds, **excluding `reasoning_tokens`** (a subset of `output_tokens`; adding it would
/// double count). The watermark only decides "has it advanced"; it is not a usage measure —
/// a separate scanner owns usage.
///
/// ⚠️ Hermes **cannot report "waiting for permission"**: the `sessions` table only has counters
/// and closing fields, no pending-approval state; the authorization prompt lives entirely inside
/// the TUI process. So this tailer never emits `.waiting(reason: .permission)` — stop looking
/// for that signal in the table.
public final class HermesStateTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    /// A session's phase as seen by this tailer (decides which event the same row emits next)
    private enum Phase {
        case live      // start/heartbeat emitted, not yet closed
        case ended     // closed via `ended_at`
        case reaped    // quiet past the threshold, closed as idle (`ended_at` still empty)
    }

    private struct SessionState {
        var sessionId: String
        var cwd: String?
        var progress: Int64
        var phase: Phase
        var lastProgressAt: Date
    }

    private struct Row {
        var sessionId: String
        var progress: Int64
        var startedAt: Date
        var endedAt: Date?
        var endReason: String?
        var title: String?
        var cwd: String?
    }

    private let stateDBs: () -> [URL]
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let maxSessions: Int
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.hermes-tailer")
    private var timer: DispatchSourceTimer?

    /// key = "<dbPath>|<sessionId>": each profile has its own state.db, so identical session ids
    /// could in theory collide; including the db path in the key keeps them apart.
    private var states: [String: SessionState] = [:]
    /// Db paths whose watermark is established (the first scan only records watermarks, no history
    /// replay)
    private var baselined = Set<String>()

    static let healthName = "Hermes 会话监视"

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stateDBs: (() -> [URL])? = nil,
        staleThreshold: TimeInterval = 300,
        recentWindow: TimeInterval = 86400,
        maxSessions: Int = 200,
        handler: @escaping Handler
    ) {
        self.stateDBs = stateDBs ?? { HermesPaths.allStateDBs(environment: environment) }
        self.staleThreshold = staleThreshold
        self.recentWindow = recentWindow
        self.maxSessions = maxSessions
        self.handler = handler
    }

    /// One pass every 5s: a Hermes turn often takes tens of seconds; polling faster just opens
    /// read-only connections for nothing
    public func start(pollInterval: TimeInterval = 5) {
        HealthRegistry.shared.register(Self.healthName, expectedInterval: pollInterval)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // leeway lets the system coalesce wakeups to save power; must stay below the poll interval
        // (100ms for the 1s tier)
        let leeway: DispatchTimeInterval = pollInterval >= 2
            ? .milliseconds(500) : .milliseconds(100)
        timer.schedule(deadline: .now() + 1, repeating: pollInterval, leeway: leeway)
        timer.setEventHandler { [weak self] in self?.scanOnce() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Public so tests and launch can call it synchronously
    public func scanOnce(now: Date = Date()) {
        HealthRegistry.shared.beat(Self.healthName)
        for dbPath in stateDBs() {
            poll(dbPath: dbPath, now: now)
        }
        reapIdle(now: now)
    }

    private func poll(dbPath: URL, now: Date) {
        // Open read-only (WAL-aware; never immutable=1, or new un-checkpointed writes are
        // invisible)
        guard let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return }
        let rows = fetch(db: db, now: now)
        let isBaseline = !baselined.contains(dbPath.path)
        baselined.insert(dbPath.path)

        var seen = Set<String>()
        for row in rows {
            let key = "\(dbPath.path)|\(row.sessionId)"
            seen.insert(key)
            if isBaseline {
                // First scan: only record watermarks. Otherwise every app launch would replay
                // historic sessions as a pile of cards.
                remember(row, key: key, phase: row.endedAt == nil ? .reaped : .ended, at: now)
                continue
            }
            inspect(row, key: key, now: now)
        }
        prune(dbPath: dbPath, seen: seen)
    }

    private func inspect(_ row: Row, key: String, now: Date) {
        let previous = states[key]

        if let endedAt = row.endedAt {
            let closed = previous?.phase == .ended || previous?.phase == .reaped
            remember(row, key: key, phase: .ended, at: now)
            // Sessions already closed via ended_at or as idle never produce another card (otherwise
            // history gets two rows)
            guard !closed else { return }
            emit(
                .taskFinished(
                    outcome: Self.outcome(endReason: row.endReason),
                    title: Self.label(row),
                    detail: row.endReason?.isEmpty == false ? row.endReason : nil),
                row: row, at: endedAt, now: now)
            return
        }

        // Empty ended_at = still running (or left empty forever after a kill; staleThreshold is the
        // fallback)
        guard let previous else {
            // New rows appearing after the watermark: only genuinely just-started sessions count as
            // active; old rows (e.g. a new profile db, pruned rows) silently backfill the watermark
            // without fake cards.
            let fresh = now.timeIntervalSince(row.startedAt) <= staleThreshold
            remember(row, key: key, phase: fresh ? .live : .reaped, at: now)
            if fresh {
                emit(.taskStarted(title: Self.label(row)), row: row, at: now, now: now)
            }
            return
        }

        guard row.progress > previous.progress else { return }  // no progress: leave the idle decision to reapIdle
        remember(row, key: key, phase: .live, at: now)
        // The table has no "current tool name", so heartbeats can only carry tool: nil
        let kind: TaskEvent.Kind = previous.phase == .live
            ? .activity(tool: nil)
            : .taskStarted(title: Self.label(row))
        emit(kind, row: row, at: now, now: now)
    }

    /// Active sessions quiet for longer than staleThreshold are closed as idle: Hermes only writes
    /// ended_at on a clean exit, so a Ctrl-C'd / killed session stays empty forever, and without
    /// closing it the island would keep a running card that never goes away.
    private func reapIdle(now: Date) {
        for (key, var state) in states
        where state.phase == .live && now.timeIntervalSince(state.lastProgressAt) > staleThreshold {
            state.phase = .reaped
            states[key] = state
            HealthRegistry.shared.event(Self.healthName)
            handler(
                TaskEvent(
                    source: .hermes, sessionId: state.sessionId,
                    kind: .taskFinished(outcome: .success, title: nil, detail: nil),
                    timestamp: now, cwd: state.cwd),
                false)
        }
    }

    private func remember(_ row: Row, key: String, phase: Phase, at now: Date) {
        states[key] = SessionState(
            sessionId: row.sessionId, cwd: row.cwd, progress: row.progress,
            phase: phase, lastProgressAt: now)
    }

    /// Drops rows that fell out of the time window so states doesn't grow forever; active rows are
    /// kept (cleared after reapIdle closes them)
    private func prune(dbPath: URL, seen: Set<String>) {
        let prefix = "\(dbPath.path)|"
        for (key, state) in states
        where key.hasPrefix(prefix) && state.phase != .live && !seen.contains(key) {
            states.removeValue(forKey: key)
        }
    }

    private func fetch(db: SQLiteDB, now: Date) -> [Row] {
        let cutoff = now.timeIntervalSince1970 - recentWindow
        // Top-level sessions only: child sessions (spawned by delegate_task) shouldn't take their
        // own spot on the island
        let rows = (try? db.query("""
            SELECT id,
                   COALESCE(message_count, 0) + COALESCE(tool_call_count, 0)
                     + COALESCE(api_call_count, 0)
                     + COALESCE(input_tokens, 0) + COALESCE(output_tokens, 0)
                     + COALESCE(cache_read_tokens, 0) + COALESCE(cache_write_tokens, 0),
                   started_at, ended_at, end_reason, title, cwd
            FROM sessions
            WHERE (parent_session_id IS NULL OR parent_session_id = '')
              AND COALESCE(archived, 0) = 0
              AND started_at >= ?
            ORDER BY started_at DESC
            LIMIT ?
            """, [.real(cutoff), .int(Int64(maxSessions))]) { row in
            Row(
                sessionId: row.text(0) ?? "",
                progress: row.int(1),
                startedAt: Date(timeIntervalSince1970: row.real(2)),
                endedAt: row.date(3),
                endReason: row.text(4),
                title: row.text(5),
                cwd: row.text(6).flatMap { $0.isEmpty ? nil : $0 })
        }) ?? []
        return rows.filter { !$0.sessionId.isEmpty }
    }

    private func emit(_ kind: TaskEvent.Kind, row: Row, at timestamp: Date, now: Date) {
        HealthRegistry.shared.event(Self.healthName)
        let isStale = now.timeIntervalSince(timestamp) > staleThreshold
        handler(
            TaskEvent(
                source: .hermes, sessionId: row.sessionId, kind: kind,
                timestamp: timestamp, cwd: row.cwd, sessionStartedAt: row.startedAt),
            isStale)
    }

    /// Card title: prefer `title` (the session name Hermes generates), degrading to a 6-char short
    /// code from the id tail
    private static func label(_ row: Row) -> String? {
        if let title = row.title, let summary = summarizeTitle(title) { return summary }
        let short = row.sessionId.split(separator: "_").last.map(String.init) ?? row.sessionId
        return short.isEmpty ? nil : "#\(short)"
    }

    /// `end_reason` → how it ended. Values change across Hermes versions, so they are classified
    /// loosely by keyword; anything unrecognized counts as a normal completion (better to
    /// under-report errors than show the user a false red dot).
    private static func outcome(endReason: String?) -> TaskOutcome {
        let reason = (endReason ?? "").lowercased()
        func mentions(_ tokens: [String]) -> Bool { tokens.contains { reason.contains($0) } }
        if mentions(["error", "fail", "crash", "exception", "fatal"]) { return .error }
        if mentions(["interrupt", "cancel", "abort", "kill", "signal", "timeout"]) {
            return .interrupted
        }
        return .success
    }
}
