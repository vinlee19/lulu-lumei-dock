import EurekaKit
import EurekaStore
import Foundation

/// Tails opencode.db for live events. opencode has no hook/notify callback, so this is the only
/// live channel.
/// The database holds two generations of tables, each with its own rowid watermark and independent
/// of the other (a failed query on one side doesn't hold back the other):
///   - 1.x: the append-only `event` table (`OpencodeEventDecoder`)
///   - 2.x: the `session_message` table (`OpencodeSessionMessageDecoder`). opencode 2.x and
///     OpenChamber's bundled `opencode serve` write only this generation; `event` stays at 0 rows
/// Opens the external database read-only; the first scan baselines to the current max rowid and
/// doesn't replay history (same as Codex initialScan).
/// Child-session (subagent) events are filtered out by parent_id, and so are Eureka's own summary
/// runs (OpenCode has no ephemeral mode; those sessions live under `SummaryWorkspacePaths.root()`).
public final class OpencodeEventTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let dbPath: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.opencode-tailer")
    private var timer: DispatchSourceTimer?

    private var lastRowid: Int64 = -1  // -1 = uninitialized (first scan sets the baseline)
    private var knownTopLevel = Set<String>()
    private var knownChild = Set<String>()

    private var lastMessageRowid: Int64 = -1  // session_message watermark, like lastRowid
    /// 2.x session ownership cache: ignored = child session, emits no events; live carries the cwd
    private var v2Sessions: [String: V2Session] = [:]
    private enum V2Session {
        case live(cwd: String?)
        case ignored
    }

    /// An event whose own timestamp is older than this many seconds is backlog: it only enters
    /// history/usage and never triggers island animations (same rule as the spool / Hermes
    /// tailer; a message's completion time may be weeks old)
    private let staleThreshold: TimeInterval = 300

    static let healthName = "opencode 事件监视"

    /// Root of the app-managed summary workspace; sessions under it are internal
    private let summaryRoot: URL

    public init(
        dbPath: URL, summaryRoot: URL = SummaryWorkspacePaths.root(),
        handler: @escaping Handler
    ) {
        self.dbPath = dbPath
        self.summaryRoot = summaryRoot
        self.handler = handler
    }

    public func start(pollInterval: TimeInterval = 2) {
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
    public func scanOnce() {
        HealthRegistry.shared.beat(Self.healthName)
        guard FileManager.default.fileExists(atPath: dbPath.path),
              let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return }
        let now = Date()
        scanEventTable(db, now: now)
        scanSessionMessages(db, now: now)
    }

    /// Advances the rowid watermark; returns nil = skip this tick (first scan / failed query /
    /// table shrank).
    ///
    /// A failed watermark query (IO hiccup / lock timeout / table briefly unavailable) must bail
    /// out with the watermark intact and retry on the next tick. Previously a failure was read as 0
    /// and then treated as a "rowid regression" that reset the watermark to zero — the next tick
    /// replayed all 25,571 historical events as live events (observed 2026-09-05: the island queued
    /// hundreds of finished cards it couldn't clear, and 22 old sessions from July/August were
    /// rebuilt as running, then judged "interrupted" a minute later and written to history).
    private func baseline(_ watermark: inout Int64, table: String, db: SQLiteDB) -> Int64? {
        guard let maxRowid = (try? db.query("SELECT COALESCE(MAX(rowid), 0) FROM \(table)") {
            $0.int(0)
        })?.first else { return nil }
        if watermark < 0 || maxRowid < watermark {
            // First scan, or the table was rebuilt smaller (a real rowid regression): only
            // baseline, never replay — a rebuilt table holds history too, and replaying it as live
            // would flood the island just the same; later new events still arrive incrementally
            watermark = maxRowid
            return nil
        }
        return watermark
    }

    private func emit(_ event: TaskEvent, now: Date) {
        HealthRegistry.shared.event(Self.healthName)
        // Judge backlog by the event's own timestamp: even if the watermark is lost and
        // history replays, messages completed weeks ago only go to history/usage and never
        // queue up as island cards
        handler(event, now.timeIntervalSince(event.timestamp) > staleThreshold)
    }

    // MARK: - 1.x: event table

    private func scanEventTable(_ db: SQLiteDB, now: Date) {
        guard let from = baseline(&lastRowid, table: "event", db: db) else { return }
        let rows = (try? db.query("""
            SELECT rowid, type, data FROM event WHERE rowid > ? ORDER BY rowid ASC
            """, [.int(from)]) { row -> (Int64, String, Data?) in
            (row.int(0), row.text(1) ?? "", row.text(2).flatMap { $0.data(using: .utf8) })
        }) ?? []

        for (rowid, type, dataBytes) in rows {
            lastRowid = max(lastRowid, rowid)
            guard let dataBytes,
                  let object = try? JSONSerialization.jsonObject(with: dataBytes),
                  let data = object as? [String: Any] else { continue }
            for event in OpencodeEventDecoder.decode(type: type, data: data)
            where !isIgnoredSession(event.sessionId, db: db) {
                emit(event, now: now)
            }
        }
    }

    /// Whether the session emits no events: a subagent (session.parent_id non-empty) or an internal
    /// summary run (directory under the summary workspace). The table is queried once per session
    /// id and cached.
    private func isIgnoredSession(_ sessionID: String, db: SQLiteDB) -> Bool {
        if knownChild.contains(sessionID) { return true }
        if knownTopLevel.contains(sessionID) { return false }
        let rows = (try? db.query(
            "SELECT parent_id, directory FROM session WHERE id = ?",
            [.text(sessionID)]) { row in (row.text(0), row.text(1)) }) ?? []
        let parent = rows.first?.0 ?? nil
        let child = (parent?.isEmpty == false)
            || SummaryWorkspacePaths.isInternal(rows.first?.1 ?? nil, under: summaryRoot)
        if child { knownChild.insert(sessionID) } else { knownTopLevel.insert(sessionID) }
        return child
    }

    // MARK: - 2.x: session_message table

    private func scanSessionMessages(_ db: SQLiteDB, now: Date) {
        guard let from = baseline(&lastMessageRowid, table: "session_message", db: db) else {
            return
        }
        // If the upgrade migration runs while the app is up, 1.x history messages are bulk-inserted
        // under their original ids: exclude them row by row so they aren't emitted as live events
        let notCopiedFromV1 = db.tableExists("message")
            ? "AND NOT EXISTS (SELECT 1 FROM message o WHERE o.id = m.id)" : ""
        let rows = (try? db.query("""
            SELECT m.rowid, m.session_id, m.type, m.data FROM session_message m
            WHERE m.rowid > ? \(notCopiedFromV1) ORDER BY m.rowid ASC
            """, [.int(from)]) { row -> (Int64, String, String, Data?) in
            (row.int(0), row.text(1) ?? "", row.text(2) ?? "",
             row.text(3).flatMap { $0.data(using: .utf8) })
        }) ?? []

        for (rowid, sessionID, type, dataBytes) in rows {
            lastMessageRowid = max(lastMessageRowid, rowid)
            guard case .live(let cwd) = v2Session(sessionID, db: db),
                  let dataBytes,
                  let object = try? JSONSerialization.jsonObject(with: dataBytes),
                  let data = object as? [String: Any] else { continue }
            for event in OpencodeSessionMessageDecoder.decode(
                sessionID: sessionID, type: type, data: data, cwd: cwd) {
                emit(event, now: now)
            }
        }
    }

    /// 2.x session ownership: child sessions (non-empty parent_id) emit no events. Each session id
    /// is looked up in the table only once.
    private func v2Session(_ sessionID: String, db: SQLiteDB) -> V2Session {
        if let cached = v2Sessions[sessionID] { return cached }
        let rows = (try? db.query(
            "SELECT parent_id, directory FROM session_v2 WHERE id = ?",
            [.text(sessionID)]) { row in (row.text(0), row.text(1)) }) ?? []
        // Message visible before its session row (shouldn't happen): treat it as top-level, don't
        // cache, look it up again next time
        guard let (parent, directory) = rows.first else { return .live(cwd: nil) }
        let internalRun = SummaryWorkspacePaths.isInternal(directory, under: summaryRoot)
        let resolved: V2Session = parent?.isEmpty == false || internalRun
            ? .ignored : .live(cwd: directory)
        v2Sessions[sessionID] = resolved
        return resolved
    }
}
