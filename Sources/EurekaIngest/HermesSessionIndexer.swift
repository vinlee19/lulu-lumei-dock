import EurekaKit
import EurekaStore
import Foundation

/// Hermes 会话索引：只读 `state.db` 的 `sessions` 表 → `AgentSessionInfo`。
///
/// 与其它源的差异：
///   - 时间是 epoch **秒**（opencode 那张表是毫秒）；
///   - 没有 transcript 文件，`transcriptPath` 记 state.db 路径、`sizeBytes` 记 0
///     （`TranscriptReader.loadHermes` 再用它 + session id 回查 `messages`）；
///   - 会话可能仍在跑（`ended_at IS NULL`），最近活跃时间取
///     `ended_at` → 该会话最后一条消息 → `started_at` 的第一个非空值；
///   - 多 profile 各有独立 state.db，故对外入口是 `indexAll`。
///
/// 只取顶层会话（`parent_session_id` 空）：子会话是 delegate_task 的子代理与压缩分裂产物，
/// 不进浏览列表。归档会话（`archived = 1`）同样跳过。
public enum HermesSessionIndexer {
    /// 单库索引
    public static func index(
        dbPath: URL,
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        guard FileManager.default.fileExists(atPath: dbPath.path),
              let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return [] }
        let cutoff = now.timeIntervalSince1970 - window
        let rows = (try? db.query("""
            SELECT s.id, s.cwd, s.title, s.started_at,
                   COALESCE(s.ended_at,
                            (SELECT MAX(m.timestamp) FROM messages m WHERE m.session_id = s.id),
                            s.started_at)
            FROM sessions s
            WHERE (s.parent_session_id IS NULL OR s.parent_session_id = '')
              AND s.archived = 0
              AND s.started_at >= ?
            ORDER BY s.started_at DESC
            LIMIT ?
            """, [.real(cutoff), .int(Int64(maxSessions))]) { row in
            AgentSessionInfo(
                source: .hermes,
                id: row.text(0) ?? "",
                cwd: row.text(1).flatMap { $0.isEmpty ? nil : $0 },
                name: row.text(2).flatMap { $0.isEmpty ? nil : $0 },
                startedAt: Date(timeIntervalSince1970: row.real(3)),
                lastActiveAt: Date(timeIntervalSince1970: row.real(4)),
                sizeBytes: 0,
                transcriptPath: dbPath.path)
        }) ?? []
        return rows.filter { !$0.id.isEmpty }
    }

    /// 默认 home + 各 profile 的 state.db 合并索引（按最近活跃倒序、整体限量）
    public static func indexAll(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        var all: [AgentSessionInfo] = []
        for db in HermesPaths.allStateDBs(environment: environment) {
            all += index(dbPath: db, window: window, maxSessions: maxSessions, now: now)
        }
        return Array(all.sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(maxSessions))
    }

    /// 近期会话 cwd 集合（供项目级发现并入；Hermes 无项目级技能/记忆，仅计划目录用得上）
    public static func recentDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maxSessions: Int = 300
    ) -> [String] {
        indexAll(environment: environment, maxSessions: maxSessions).compactMap(\.cwd)
    }
}
