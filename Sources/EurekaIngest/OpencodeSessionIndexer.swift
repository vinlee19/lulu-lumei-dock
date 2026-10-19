import EurekaKit
import EurekaStore
import Foundation

/// opencode 会话索引：只读 `opencode.db` → `AgentSessionInfo`。两代会话表都读：
/// 1.x 的 `session` 与 2.x 的 `session_v2`（opencode 2.x / OpenChamber 只写后者）。
/// 升级时 1.x 会话会被原 id 复制进 `session_v2`，同 id 只保留一条（取 2.x 那行）。
/// 只取顶层会话（parent_id 空）；子会话是 opencode 的子 agent，不进浏览列表。
/// 时间是 epoch 毫秒；opencode 无 transcript 文件，故 sizeBytes 记 0。
public enum OpencodeSessionIndexer {
    public static func index(
        dbPath: URL,
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        guard FileManager.default.fileExists(atPath: dbPath.path),
              let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return [] }
        let cutoffMs = (now.timeIntervalSince1970 - window) * 1000

        func query(_ table: String) -> [AgentSessionInfo] {
            // 表不存在（1.x 库没有 session_v2）→ 查询失败 → 空
            (try? db.query("""
                SELECT id, directory, title, time_created, time_updated
                FROM \(table)
                WHERE (parent_id IS NULL OR parent_id = '')
                  AND time_updated >= ?
                ORDER BY time_updated DESC
                LIMIT ?
                """, [.real(cutoffMs), .int(Int64(maxSessions))]) { row in
                AgentSessionInfo(
                    source: .opencode,
                    id: row.text(0) ?? "",
                    cwd: row.text(1),
                    name: row.text(2).flatMap { $0.isEmpty ? nil : $0 },
                    startedAt: Date(timeIntervalSince1970: row.real(3) / 1000),
                    lastActiveAt: Date(timeIntervalSince1970: row.real(4) / 1000),
                    sizeBytes: 0,
                    transcriptPath: dbPath.path)
            }) ?? []
        }

        let v2 = query("session_v2")
        let v2Ids = Set(v2.map(\.id))
        let merged = v2 + query("session").filter { !v2Ids.contains($0.id) }
        return Array(merged
            .filter { !$0.id.isEmpty }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
            .prefix(maxSessions))
    }

    /// 顶层会话目录集合（供项目级技能/agent 发现并入）
    public static func recentDirectories(dbPath: URL, maxSessions: Int = 300) -> [String] {
        index(dbPath: dbPath, maxSessions: maxSessions).compactMap(\.cwd)
    }
}
