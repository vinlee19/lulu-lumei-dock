import EurekaStore
import Foundation

/// eureka.sqlite 的**分析快照**：把三张分析事实表（usage_records / task_history /
/// tool_calls）抽取成一个独立的小 SQLite 文件，随云备份上传，服务器侧可直接用
/// DuckDB（sqlite_scanner ATTACH）或 sqlite3 做分析（脚本见 Scripts/analytics/）。
///
/// 为什么不能像 opencode 那样整库 VACUUM 上传：
/// 1. eureka.sqlite 里就存着 sync_state / sync_runs 记账表 —— 上传后引擎落状态会改动
///    库文件本身，下一轮又判定"变了"再传，形成每轮必传的永动噪音；
/// 2. 整库还带全文索引（fts_docs / knowledge_docs），体积可达数百 MB，分析用不上。
/// 所以：指纹只看三张事实表（行数 + 最大 rowid），变了才重建快照；快照文件本身
/// 走常规单文件枚举 → size/mtime diff，与其它备份文件同一条路。
public enum EurekaDBSnapshot {
    /// 抽取进快照的分析事实表（服务器侧 bootstrap.sql 按这个清单写查询）
    public static let tables = ["usage_records", "task_history", "tool_calls"]

    /// 事实表指纹：`表=行数:最大rowid` 逐表拼接。库不存在/查询失败返回 nil。
    public static func fingerprint(dbPath: URL) -> String? {
        guard FileManager.default.fileExists(atPath: dbPath.path),
              let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return nil }
        var parts: [String] = []
        for table in tables {
            guard let row = try? db.query(
                "SELECT count(*), coalesce(max(rowid), 0) FROM \(table)",
                map: { ($0.int(0), $0.int(1)) }
            ).first else { return nil }
            parts.append("\(table)=\(row.0):\(row.1)")
        }
        return parts.joined(separator: ",")
    }

    /// 指纹变化时才重建快照（临时文件 + 原子替换 + 指纹侧车），返回是否重建。
    /// best-effort：任何失败安静返回 false，本轮照常同步旧快照（若有）。
    @discardableResult
    public static func materializeIfChanged(dbPath: URL, snapshotPath: URL) -> Bool {
        guard let fingerprint = fingerprint(dbPath: dbPath) else { return false }
        let fm = FileManager.default
        let sidecar = URL(fileURLWithPath: snapshotPath.path + ".fingerprint")
        if (try? String(contentsOf: sidecar, encoding: .utf8)) == fingerprint,
           fm.fileExists(atPath: snapshotPath.path) {
            return false
        }
        let temp = URL(fileURLWithPath: snapshotPath.path + ".tmp")
        do {
            try fm.createDirectory(
                at: snapshotPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: temp)
            // 快照连接以自身为主库、ATTACH 源库只做 SELECT；事务内整批复制保证三表一致。
            // 作用域块保证连接在 rename 前关闭（避免半开文件被替换）。
            do {
                let out = try SQLiteDB(path: temp.path)
                let escaped = dbPath.path.replacingOccurrences(of: "'", with: "''")
                try out.execute("ATTACH '\(escaped)' AS src")
                try out.transaction {
                    for table in tables {
                        try out.execute("CREATE TABLE \(table) AS SELECT * FROM src.\(table)")
                    }
                }
                try out.execute("DETACH src")
                // SQLiteDB 建库默认 WAL，但 WAL 标头的文件没有 -shm 就**无法只读打开**
                // （服务器侧下载单文件后 sqlite3/DuckDB 只读 ATTACH 会 CANTOPEN）。
                // 快照必须是自包含单文件 → 转回 DELETE journal 再关连接。
                try out.execute("PRAGMA journal_mode=DELETE")
            }
            try? fm.removeItem(at: snapshotPath)
            try fm.moveItem(at: temp, to: snapshotPath)
            try fingerprint.write(to: sidecar, atomically: true, encoding: .utf8)
            return true
        } catch {
            try? fm.removeItem(at: temp)
            return false
        }
    }
}
