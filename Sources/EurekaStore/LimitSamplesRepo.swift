import Foundation

/// Rate-limit percentage sample repo: one row per rate-limit refresh, used to predict "when the
/// quota fills". Observed data (not re-derivable) → treated like task_history, never DROPped on
/// upgrade; periodically pruned to 14 days.
public final class LimitSamplesRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    public func insert(source: String, window: String, percent: Double, ts: Date) throws {
        try db.run(
            "INSERT INTO limit_samples (ts, source, window, percent) VALUES (?,?,?,?)",
            [.date(ts), .text(source), .text(window), .real(percent)])
    }

    /// Samples for one source and window since `since` (time ascending)
    public func samples(
        source: String, window: String, since: Date
    ) throws -> [(ts: Date, percent: Double)] {
        try db.query("""
        SELECT ts, percent FROM limit_samples
        WHERE source = ? AND window = ? AND ts >= ?
        ORDER BY ts ASC
        """, [.text(source), .text(window), .date(since)]) { row in
            (ts: Date(timeIntervalSince1970: row.real(0)), percent: row.real(1))
        }
    }

    public func prune(before: Date) throws {
        try db.run("DELETE FROM limit_samples WHERE ts < ?", [.date(before)])
    }
}
