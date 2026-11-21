import EurekaStore
import Foundation

/// WorkBuddy's own record of its sessions (`~/.workbuddy/workbuddy.db`, table `sessions`): the
/// title it shows (its transcripts carry one for only a few sessions), the context window each
/// session runs with, and whether a session is a scheduled automation run.
///
/// Read-only and best effort. The database is plain SQLite in WAL mode that WorkBuddy holds open,
/// so it is opened `SQLITE_OPEN_READONLY` on a plain path (never `immutable=1`, which would hide
/// everything not yet checkpointed). Rows are cached and reloaded at most every `refreshInterval`,
/// or sooner (bounded by `missRetryInterval`) when asked about a session it hasn't seen, since a
/// new session's row and its transcript appear at about the same time. A failed read keeps the
/// previous rows: an unreadable database must never look like "no sessions", which would let a
/// scheduled run through as an interactive one.
public final class WorkBuddySessionCatalog: @unchecked Sendable {
    /// One cache for the app: the live channel, the session list and the audit scanner all ask
    public static let shared = WorkBuddySessionCatalog()

    private let databaseURL: URL
    private let refreshInterval: TimeInterval
    private let missRetryInterval: TimeInterval
    private let lock = NSLock()
    private var rows: [String: CodeBuddySessionHints] = [:]
    private var loadedAt: Date?
    private var lastAttemptAt: Date?

    public init(
        databaseURL: URL = WorkBuddyPaths.database(),
        refreshInterval: TimeInterval = 10,
        missRetryInterval: TimeInterval = 2
    ) {
        self.databaseURL = databaseURL
        self.refreshInterval = refreshInterval
        self.missRetryInterval = missRetryInterval
    }

    /// For the CodeBuddy-family tailer / indexer / audit scanner. Holds the catalog strongly: the
    /// consumers keep only this closure, and a weak capture let a catalog nobody else held vanish,
    /// turning every lookup into "unknown" (scheduled runs then went through as interactive ones).
    /// The catalog holds no closures, so there is no cycle.
    public var lookup: CodeBuddySessionLookup {
        { sessionId in self.hints(for: sessionId) }
    }

    public func hints(for sessionId: String, now: Date = Date()) -> CodeBuddySessionHints? {
        lock.lock()
        defer { lock.unlock() }
        let stale = loadedAt.map { now.timeIntervalSince($0) >= refreshInterval } ?? true
        let missing = rows[sessionId] == nil
            && (lastAttemptAt.map { now.timeIntervalSince($0) >= missRetryInterval } ?? true)
        if stale || missing { reload(now: now) }
        return rows[sessionId]
    }

    /// Caller holds the lock
    private func reload(now: Date) {
        lastAttemptAt = now
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              let db = try? SQLiteDB(path: databaseURL.path, readOnly: true)
        else { return }
        let loaded = try? db.query("""
            SELECT id, custom_title, title, is_background_automation, context_window
            FROM sessions
            """) { row -> (String, CodeBuddySessionHints)? in
            guard let id = row.text(0), !id.isEmpty else { return nil }
            let title = [row.text(1), row.text(2)]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return (id, CodeBuddySessionHints(
                isAutomation: row.isNull(3) ? nil : row.int(3) != 0,
                title: title,
                contextWindow: row.isNull(4) ? nil : Int(row.int(4))))
        }
        // Schema drift or a locked read: keep what we had
        guard let loaded else { return }
        rows = Dictionary(loaded.compactMap { $0 }, uniquingKeysWith: { _, last in last })
        loadedAt = now
    }
}
