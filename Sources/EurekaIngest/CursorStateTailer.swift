import EurekaKit
import EurekaStore
import Foundation

/// Polls Cursor's `state.vscdb` to produce live events (Dynamic Island lifecycle).
///
/// Why polling: Cursor is an IDE with no hook / notify callback, and all session state lives only
/// in one SQLite database (same trade-off as opencode / hermes / antigravity — with no callback
/// this is the only live channel). The Cursor process keeps the database open in WAL mode, so this
/// tailer always opens it with `SQLITE_OPEN_READONLY` and **never with `immutable=1`**, or it would
/// miss new writes that haven't been checkpointed.
///
/// Each tick has two stages:
///   1. `composerHeaders` (covering index `idx_composerHeaders_1(recency, composerId)`) fetches the
///      recent-window session headers for title / ctx% / pending-permission flag; only sessions
///      whose `recency` advanced or that are still live go on to stage 2;
///   2. a point read of `composerData:<id>` decides running vs. finished and gets the tool name
///      and child sessions.
///
/// Progress watermark = bubble count + `contextTokensUsed`, used only to tell "did it advance";
/// usage accounting is `CursorUsageScanner`'s job.
///
/// Warning: top-level sessions are identified by `value.subagentInfo == nil`, **not** the
/// `isSubagent` column: on real data, child sessions (Best-of-N variants) still have
/// `isSubagent` = 0 and only carry `subagentInfo` in the JSON.
public final class CursorStateTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    /// The session's phase as this tailer sees it (decides which event the row emits next)
    private enum Phase {
        case live      // start/heartbeat already emitted, not yet closed
        case ended     // closed according to status
        case reaped    // silent past the threshold and closed as idle
    }

    private struct SessionState {
        var cwd: String?
        var progress: Int64
        var recency: Date
        var phase: Phase
        var lastProgressAt: Date
        var startedAt: Date?
        var title: String?
        var lastContextPercent: Double?
        var waiting: Bool = false
        var lastSubagents: [SubagentInfo] = []
        /// A closing status was seen but awaits one more tick to confirm
        /// (see the aborted→completed finding in inspect)
        var pendingClose: String?
        /// The transcript file already existed when this turn started → the transcript side owns
        /// the whole turn's lifecycle. **Must be fixed at turn start**: deciding mid-turn yields
        /// "start emitted by the DB side, finish left to the transcript side, which stays silent
        /// because the turn had already ended when it first saw the file" → the card hangs forever.
        var ownedByTranscript = false
    }

    /// One `composerHeaders` row (the JSON in value already flattened)
    struct Header {
        var composerId: String
        var workspaceId: String?
        var createdAt: Date?
        var recency: Date
        var title: String?
        var contextPercent: Double?
        var blocking: Bool
        var subagentIds: [String]
    }

    /// Summary of `composerData:<id>`
    struct Detail {
        var progress: Int64
        var generating: Bool
        var status: String
        var contextPercent: Double?
        var lastTool: String?
        var bubbleIds: [String]
        var subagentIds: [String]
    }

    private let dbPath: URL
    private let workspaceStorageRoot: URL
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let maxSessions: Int
    private let handler: Handler
    /// Sessions with a transcript file → lifecycle events are left to `CursorTranscriptTailer`
    /// (it has an explicit turn_ended). ctx% / child sessions / waiting-for-permission exist only
    /// in the DB, so those are still emitted.
    private let transcriptOwned: (Date) -> Set<String>
    private let queue = DispatchQueue(label: "com.vinlee.eureka.cursor-tailer")
    private var timer: DispatchSourceTimer?

    private var states: [String: SessionState] = [:]
    /// Watermark established (the first scan only records watermarks, never replays history)
    private var baselined = false

    static let healthName = "Cursor 会话监视"

    public init(
        dbPath: URL = CursorPaths.globalStateDB(),
        workspaceStorageRoot: URL = CursorPaths.workspaceStorageRoot(),
        staleThreshold: TimeInterval = 300,
        recentWindow: TimeInterval = 86400,
        maxSessions: Int = 200,
        transcriptOwned: ((Date) -> Set<String>)? = nil,
        handler: @escaping Handler
    ) {
        self.dbPath = dbPath
        self.workspaceStorageRoot = workspaceStorageRoot
        self.staleThreshold = staleThreshold
        self.recentWindow = recentWindow
        self.maxSessions = maxSessions
        self.transcriptOwned = transcriptOwned ?? { now in
            CursorTranscriptIndex.ownedComposerIds(
                cliHome: CursorPaths.cliHome(),
                workspaceStorageRoot: workspaceStorageRoot, now: now)
        }
        self.handler = handler
    }

    public func start(pollInterval: TimeInterval = 2) {
        HealthRegistry.shared.register(Self.healthName, expectedInterval: pollInterval)
        let timer = DispatchSource.makeTimerSource(queue: queue)
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

    /// Public for tests and for a synchronous call at launch
    public func scanOnce(now: Date = Date()) {
        HealthRegistry.shared.beat(Self.healthName)
        poll(now: now)
        reapIdle(now: now)
    }

    private func poll(now: Date) {
        guard FileManager.default.fileExists(atPath: dbPath.path),
            let db = try? SQLiteDB(path: dbPath.path, readOnly: true)
        else { return }
        let folders = CursorWorkspaceIndex.folders(root: workspaceStorageRoot, now: now)
        let owned = transcriptOwned(now)
        let headers = fetchHeaders(db: db, now: now)
        let isBaseline = !baselined
        baselined = true

        var seen = Set<String>()
        for header in headers {
            seen.insert(header.composerId)
            let cwd = header.workspaceId.flatMap { folders[$0] }
            if isBaseline {
                // First scan only records watermarks: otherwise every app launch would replay
                // past sessions as a pile of cards
                guard let detail = fetchDetail(db: db, composerId: header.composerId) else {
                    continue
                }
                states[header.composerId] = SessionState(
                    cwd: cwd, progress: detail.progress, recency: header.recency,
                    phase: Self.isClosed(detail.status) ? .ended : .reaped, lastProgressAt: now,
                    startedAt: header.createdAt, title: header.title,
                    lastContextPercent: header.contextPercent)
                continue
            }
            inspect(
                header, cwd: cwd, db: db, now: now,
                owned: owned.contains(header.composerId))
        }
        prune(seen: seen)
    }

    private func inspect(
        _ header: Header, cwd: String?, db: SQLiteDB, now: Date, owned: Bool
    ) {
        let previous = states[header.composerId]
        // Skip the composerData read (the biggest cost) for sessions that neither advanced nor are
        // running. A pending close must pass through: it relies on "the watermark didn't move on
        // the next tick" to accept the final status.
        if let previous, previous.phase != .live, previous.pendingClose == nil,
            previous.recency >= header.recency { return }
        guard let detail = fetchDetail(db: db, composerId: header.composerId) else { return }

        var state = previous ?? SessionState(
            cwd: cwd, progress: detail.progress, recency: header.recency,
            phase: .reaped, lastProgressAt: now, startedAt: header.createdAt,
            title: header.title, lastContextPercent: nil)
        state.cwd = cwd ?? state.cwd
        state.recency = header.recency
        state.startedAt = header.createdAt ?? state.startedAt
        if let title = header.title { state.title = title }

        let advanced = previous == nil || detail.progress > previous!.progress
        state.progress = detail.progress  // write the watermark back, or advanced stays true
        let fresh = now.timeIntervalSince(header.recency) <= staleThreshold
        // `generatingBubbleIds` was always empty on real data (Cursor doesn't persist a
        // generating state), so it's only a safety net; liveness really comes from "the watermark
        // is advancing and the status hasn't closed".
        let running = detail.generating || (advanced && !Self.isClosed(detail.status))

        // Waiting-for-permission must be checked even when the watermark doesn't advance: being
        // stuck on a permission prompt is exactly when nothing moves, so inside the running branch
        // it would never fire.
        if state.phase == .live { emitWaiting(header, state: &state, now: now) }

        if running {
            state.pendingClose = nil
            if state.phase != .live {
                // Old sessions that surface after the watermark is set get no fake card: only
                // ones that really just moved count as active
                state.phase = fresh ? .live : .reaped
                state.lastProgressAt = now
                state.ownedByTranscript = owned
                states[header.composerId] = state
                if fresh && !owned {
                    emit(.taskStarted(title: state.title), composerId: header.composerId,
                        state: state, at: now, now: now)
                }
            } else {
                state.lastProgressAt = now
                states[header.composerId] = state
                if !state.ownedByTranscript {
                    emit(.activity(tool: detail.lastTool), composerId: header.composerId,
                        state: state, at: now, now: now)
                }
            }
            // A session that only went live this tick missed the call above, so call it again here;
            // `emitWaiting` only emits on a flip, so repeated calls are no-ops.
            emitWaiting(header, state: &state, now: now)
            emitContext(header, detail: detail, state: &state, now: now)
            emitSubagents(header, detail: detail, db: db, state: &state, now: now)
            states[header.composerId] = state
            return
        }

        guard Self.isClosed(detail.status) else {
            // Status not closed and no progress (e.g. an old session just opened): only update the
            // watermark. Any pending close is void — the status is no longer a closing one.
            state.pendingClose = nil
            states[header.composerId] = state
            return
        }

        // A closing status **must wait one tick before it's final**: real data showed status
        // written as `aborted` then `completed` within one turn (f704e4ec, twice within 2s), so
        // closing immediately would record a successful turn as interrupted. Accept it only once
        // "the status is still closing and the watermark stopped advancing", which lands on the
        // final status.
        guard let pending = state.pendingClose, pending == detail.status, !advanced else {
            state.pendingClose = detail.status
            states[header.composerId] = state
            return
        }
        state.pendingClose = nil

        // A whole turn finished without any poll catching it (turn shorter than the poll interval)
        // → emit a start card too, or the turn vanishes from history entirely. An old session that
        // merely gets touched doesn't count; `fresh` guards against that.
        let wasLive = state.phase == .live
        guard wasLive || fresh else {
            state.phase = .ended
            states[header.composerId] = state
            return
        }
        state.phase = .ended
        state.waiting = false
        state.lastSubagents = []
        states[header.composerId] = state
        // Only the ownership fixed at turn start counts: a transcript file that appears
        // mid-turn can't take over the finish
        guard !state.ownedByTranscript else { return }
        if !wasLive {
            emit(.taskStarted(title: state.title), composerId: header.composerId,
                state: state, at: now, now: now)
        }
        emit(
            .taskFinished(outcome: Self.outcome(status: detail.status), title: state.title,
                detail: nil),
            composerId: header.composerId, state: state, at: now, now: now)
    }

    /// `hasBlockingPendingActions` = Cursor is waiting for the user to confirm (tool permission /
    /// blocking question). Emitted once on the flip; resetting is left to the next `.activity`
    /// (TaskStore moves waiting back to running).
    /// Warning: **it has not yet been observed actually flipping to true**: sampling a real session
    /// with command execution end to end, the field stayed 0. The field name exists and the cost is
    /// one boolean comparison, so it stays; but don't treat "Cursor shows a waiting-for-permission
    /// card" as verified behavior — on a real permission prompt it may never be written to disk at
    /// all (same situation as Hermes).
    private func emitWaiting(_ header: Header, state: inout SessionState, now: Date) {
        guard header.blocking != state.waiting else { return }
        state.waiting = header.blocking
        guard header.blocking else { return }
        emit(.waiting(reason: .permission, message: nil), composerId: header.composerId,
            state: state, at: now, now: now)
    }

    /// ctx% comes straight from Cursor's own `contextUsagePercent` (not our estimate), with
    /// CodeBuddy's ≥0.5pt throttle so the UI isn't refreshed every tick
    private func emitContext(
        _ header: Header, detail: Detail, state: inout SessionState, now: Date
    ) {
        guard let percent = detail.contextPercent ?? header.contextPercent, percent > 0 else {
            return
        }
        let clamped = min(100, max(0, percent))
        if let last = state.lastContextPercent, abs(last - clamped) < 0.5 { return }
        state.lastContextPercent = clamped
        emit(.contextUpdate(percent: clamped), composerId: header.composerId, state: state,
            at: now, now: now)
    }

    /// Child-session snapshot: both `subagentComposerIds` (real subagents) and `subComposerIds`
    /// (Best-of-N parallel variants) are shown as subagents — the island box is meant to show "how
    /// many parallel runs are under the parent session".
    private func emitSubagents(
        _ header: Header, detail: Detail, db: SQLiteDB, state: inout SessionState, now: Date
    ) {
        let ids = detail.subagentIds.isEmpty ? header.subagentIds : detail.subagentIds
        guard !ids.isEmpty else {
            if !state.lastSubagents.isEmpty {
                state.lastSubagents = []
                emit(.subagentsUpdated([]), composerId: header.composerId, state: state,
                    at: now, now: now)
            }
            return
        }
        let subagents = ids.compactMap { childSubagent(db: db, composerId: $0) }
        guard subagents != state.lastSubagents else { return }
        state.lastSubagents = subagents
        emit(.subagentsUpdated(subagents), composerId: header.composerId, state: state,
            at: now, now: now)
    }

    private func childSubagent(db: SQLiteDB, composerId: String) -> SubagentInfo? {
        guard let detail = fetchDetail(db: db, composerId: composerId) else { return nil }
        let header = fetchHeader(db: db, composerId: composerId)
        let status: SubagentInfo.Status
        switch detail.status {
        case "completed": status = .completed
        case "aborted": status = .failed
        default: status = detail.generating ? .running : .completed
        }
        return SubagentInfo(
            agentId: composerId,
            agentType: "cursor",
            description: header?.title ?? "",
            status: status,
            currentActivity: detail.lastTool,
            startedAt: header?.createdAt,
            finishedAt: status == .running ? nil : header?.recency)
    }

    /// Live sessions silent past staleThreshold are closed as idle: a force-quit Cursor never
    /// writes `status`, and without closing, the island keeps a running card that never goes away.
    private func reapIdle(now: Date) {
        for (composerId, var state) in states
        where state.phase == .live && now.timeIntervalSince(state.lastProgressAt) > staleThreshold {
            state.phase = .reaped
            guard !state.ownedByTranscript else {
                states[composerId] = state  // transcript side owns the finish; record phase only
                continue
            }
            state.waiting = false
            states[composerId] = state
            HealthRegistry.shared.event(Self.healthName)
            handler(
                TaskEvent(
                    source: .cursor, sessionId: composerId,
                    kind: .taskFinished(outcome: .success, title: state.title, detail: nil),
                    timestamp: now, cwd: state.cwd, sessionStartedAt: state.startedAt),
                false)
        }
    }

    /// Drop rows that fell out of the time window so states doesn't grow unbounded; live rows
    /// stay (cleared after reapIdle closes them)
    private func prune(seen: Set<String>) {
        for (composerId, state) in states
        where state.phase != .live && !seen.contains(composerId) {
            states.removeValue(forKey: composerId)
        }
    }

    // MARK: - DB reads

    private func fetchHeaders(db: SQLiteDB, now: Date) -> [Header] {
        let cutoff = Int64((now.timeIntervalSince1970 - recentWindow) * 1000)
        let rows = (try? db.query("""
            SELECT composerId, workspaceId, createdAt, recency, value
            FROM composerHeaders
            WHERE recency >= ? AND COALESCE(isArchived, 0) = 0
            ORDER BY recency DESC
            LIMIT ?
            """, [.int(cutoff), .int(Int64(maxSessions))]) { row in
            (row.text(0) ?? "", row.text(1), row.int(2), row.int(3), row.text(4))
        }) ?? []
        return rows.compactMap { header(composerId: $0.0, workspaceId: $0.1, createdAtMs: $0.2,
            recencyMs: $0.3, value: $0.4) }
    }

    private func fetchHeader(db: SQLiteDB, composerId: String) -> Header? {
        let rows = (try? db.query("""
            SELECT composerId, workspaceId, createdAt, recency, value
            FROM composerHeaders WHERE composerId = ?
            """, [.text(composerId)]) { row in
            (row.text(0) ?? "", row.text(1), row.int(2), row.int(3), row.text(4))
        }) ?? []
        return rows.first.flatMap {
            header(composerId: $0.0, workspaceId: $0.1, createdAtMs: $0.2, recencyMs: $0.3,
                value: $0.4, allowSubagent: true)
        }
    }

    private func header(
        composerId: String, workspaceId: String?, createdAtMs: Int64, recencyMs: Int64,
        value: String?, allowSubagent: Bool = false
    ) -> Header? {
        guard !composerId.isEmpty else { return nil }
        let json = value.flatMap { Self.parse($0) } ?? [:]
        // Drafts (empty sessions with no prompt sent yet) and child sessions take no island slot
        if json["isDraft"] as? Bool == true { return nil }
        if !allowSubagent, json["subagentInfo"] != nil { return nil }
        return Header(
            composerId: composerId,
            workspaceId: workspaceId.flatMap { $0.isEmpty ? nil : $0 },
            createdAt: createdAtMs > 0 ? Date(timeIntervalSince1970: Double(createdAtMs) / 1000) : nil,
            recency: Date(timeIntervalSince1970: Double(recencyMs) / 1000),
            title: (json["name"] as? String).flatMap { summarizeTitle($0) },
            contextPercent: (json["contextUsagePercent"] as? NSNumber)?.doubleValue,
            blocking: json["hasBlockingPendingActions"] as? Bool == true,
            subagentIds: Self.ids(json["subagentComposerIds"]) + Self.ids(json["subComposerIds"]))
    }

    private func fetchDetail(db: SQLiteDB, composerId: String) -> Detail? {
        let rows = (try? db.query(
            "SELECT value FROM cursorDiskKV WHERE key = ?",
            [.text("composerData:\(composerId)")]) { $0.text(0) }) ?? []
        guard let json = rows.first.flatMap({ $0 }).flatMap({ Self.parse($0) }) else { return nil }
        let bubbleIds = (json["fullConversationHeadersOnly"] as? [[String: Any]] ?? [])
            .compactMap { $0["bubbleId"] as? String }
        let contextTokens = (json["contextTokensUsed"] as? NSNumber)?.int64Value ?? 0
        return Detail(
            progress: Int64(bubbleIds.count) + contextTokens,
            generating: !Self.ids(json["generatingBubbleIds"]).isEmpty,
            status: json["status"] as? String ?? "",
            contextPercent: (json["contextUsagePercent"] as? NSNumber)?.doubleValue,
            lastTool: lastTool(db: db, composerId: composerId, bubbleIds: bubbleIds),
            bubbleIds: bubbleIds,
            subagentIds: Self.ids(json["subagentComposerIds"]) + Self.ids(json["subComposerIds"]))
    }

    /// Current tool name: walk back from the tail to the latest bubble with `toolFormerData`.
    /// Only the last 8 — looking further back finds the previous turn's tool, which misleads.
    private func lastTool(db: SQLiteDB, composerId: String, bubbleIds: [String]) -> String? {
        let tail = bubbleIds.suffix(8)
        guard !tail.isEmpty else { return nil }
        for bubbleId in tail.reversed() {
            let rows = (try? db.query(
                "SELECT value FROM cursorDiskKV WHERE key = ?",
                [.text("bubbleId:\(composerId):\(bubbleId)")]) { $0.text(0) }) ?? []
            guard let json = rows.first.flatMap({ $0 }).flatMap({ Self.parse($0) }),
                let tool = json["toolFormerData"] as? [String: Any],
                let name = tool["name"] as? String, !name.isEmpty
            else { continue }
            return CursorToolNames.displayName(name)
        }
        return nil
    }

    // MARK: - Helpers

    private func emit(
        _ kind: TaskEvent.Kind, composerId: String, state: SessionState, at timestamp: Date,
        now: Date
    ) {
        HealthRegistry.shared.event(Self.healthName)
        let isStale = now.timeIntervalSince(timestamp) > staleThreshold
        handler(
            TaskEvent(
                source: .cursor, sessionId: composerId, kind: kind,
                timestamp: timestamp, cwd: state.cwd, sessionStartedAt: state.startedAt),
            isStale)
    }

    static func parse(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func ids(_ raw: Any?) -> [String] {
        (raw as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
    }

    /// `status` values observed on real data: `completed` / `aborted` / `none` / empty
    static func isClosed(_ status: String) -> Bool {
        status == "completed" || status == "aborted"
    }

    static func outcome(status: String) -> TaskOutcome {
        status == "aborted" ? .interrupted : .success
    }
}
