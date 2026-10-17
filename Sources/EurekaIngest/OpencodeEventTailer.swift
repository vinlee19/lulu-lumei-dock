import EurekaKit
import EurekaStore
import Foundation

/// Tails the `event` table of opencode.db (append-only) for live events. opencode has no
/// hook/notify callback, so this is the only live channel. The external db is opened read-only
/// and read incrementally by an `event.rowid` watermark; the first scan baselines at the current
/// max rowid without replaying history (same as Codex initialScan). Child-session (subagent)
/// events are filtered out via session.parent_id.
public final class OpencodeEventTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let dbPath: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.opencode-tailer")
    private var timer: DispatchSourceTimer?

    private var lastRowid: Int64 = -1  // -1 = uninitialized (first scan sets the baseline)
    private var knownTopLevel = Set<String>()
    private var knownChild = Set<String>()
    /// An event whose own timestamp is older than this many seconds is backlog: it only enters
    /// history/usage and never triggers island animations (same rule as the spool / Hermes
    /// tailer; a message's completion time may be weeks old)
    private let staleThreshold: TimeInterval = 300

    static let healthName = "opencode 事件监视"

    public init(dbPath: URL, handler: @escaping Handler) {
        self.dbPath = dbPath
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

        // A failed watermark query (IO hiccup / lock timeout / table temporarily unavailable) must
        // return as-is and keep the watermark, retrying next tick. It used to read the failure as
        // 0, treat it as a "rowid regression" and reset the watermark — and the next tick replayed
        // all 25,571 historic events as live (observed 2026-09-05: the Dynamic Island queued
        // hundreds of finished cards that wouldn't clear, and 22 old sessions from July/August were
        // rebuilt as running, then judged "interrupted" a minute later and written to history).
        guard let maxRowid = (try? db.query("SELECT COALESCE(MAX(rowid), 0) FROM event") {
            $0.int(0)
        })?.first else { return }
        if lastRowid < 0 || maxRowid < lastRowid {
            // First scan, or the table was rebuilt smaller (a real rowid regression): only
            // baseline, never replay — a rebuilt table holds history too, and replaying it as live
            // would flood the island just the same; later new events still arrive incrementally
            lastRowid = maxRowid
            return
        }

        let rows = (try? db.query("""
            SELECT rowid, type, data FROM event WHERE rowid > ? ORDER BY rowid ASC
            """, [.int(lastRowid)]) { row -> (Int64, String, Data?) in
            (row.int(0), row.text(1) ?? "", row.text(2).flatMap { $0.data(using: .utf8) })
        }) ?? []

        let now = Date()
        for (rowid, type, dataBytes) in rows {
            lastRowid = max(lastRowid, rowid)
            guard let dataBytes,
                  let object = try? JSONSerialization.jsonObject(with: dataBytes),
                  let data = object as? [String: Any] else { continue }
            for event in OpencodeEventDecoder.decode(type: type, data: data)
            where !isChildSession(event.sessionId, db: db) {
                HealthRegistry.shared.event(Self.healthName)
                // Judge backlog by the event's own timestamp: even if the watermark is lost and
                // history replays, messages completed weeks ago only go to history/usage and never
                // queue up as island cards
                handler(event, now.timeIntervalSince(event.timestamp) > staleThreshold)
            }
        }
    }

    /// Whether the session is a subagent (session.parent_id non-empty). The table is queried once
    /// per session id and cached.
    private func isChildSession(_ sessionID: String, db: SQLiteDB) -> Bool {
        if knownChild.contains(sessionID) { return true }
        if knownTopLevel.contains(sessionID) { return false }
        let parents = (try? db.query(
            "SELECT parent_id FROM session WHERE id = ?", [.text(sessionID)]) { $0.text(0) }) ?? []
        let parent = parents.first ?? nil
        let child = (parent?.isEmpty == false)
        if child { knownChild.insert(sessionID) } else { knownTopLevel.insert(sessionID) }
        return child
    }
}
