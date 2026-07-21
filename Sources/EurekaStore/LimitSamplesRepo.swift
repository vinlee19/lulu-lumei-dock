import Foundation

/// 限额百分比采样仓库：每次限额刷新落一行，预测"何时打满"用。
/// 观测数据（不可重推导）→ 与 task_history 同待遇，升级不 DROP；保留 14 天定期清理。
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

    /// 某源某窗口自 since 起的采样（按时间升序）
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
