import Foundation

enum Schema {
    /// v6：新增 session_stats（每会话对话数），派生表重建全量重扫
    static let version: Int64 = 6

    static func migrate(_ db: SQLiteDB) throws {
        let current = (try? db.query("PRAGMA user_version") { $0.int(0) }.first) ?? 0
        if current < version {
            // 用量三表全部可由本地 transcript/rollout 重扫派生 → 结构变更直接重建，
            // 下轮扫描自动恢复（task_history 不动）
            try db.execute("""
            DROP TABLE IF EXISTS dedup_keys;
            DROP TABLE IF EXISTS scan_files;
            DROP TABLE IF EXISTS usage_records;
            DROP TABLE IF EXISTS session_stats;
            """)
        }
        try db.execute("""
        CREATE TABLE IF NOT EXISTS task_history (
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            session_id TEXT NOT NULL,
            title TEXT,
            cwd TEXT,
            started_at REAL,
            finished_at REAL NOT NULL,
            outcome TEXT NOT NULL,
            detail TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_history_finished
            ON task_history(finished_at DESC);

        CREATE TABLE IF NOT EXISTS usage_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL,
            model TEXT NOT NULL,
            project TEXT,
            session_id TEXT,
            ts REAL NOT NULL,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
            cache_creation_1h_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_records(ts);
        CREATE INDEX IF NOT EXISTS idx_usage_session ON usage_records(session_id);

        -- 扫描状态：offset/inode 增量续读；extra 存扫描器私有状态（如 codex 累计值）
        CREATE TABLE IF NOT EXISTS scan_files (
            path TEXT PRIMARY KEY,
            inode INTEGER NOT NULL DEFAULT 0,
            offset INTEGER NOT NULL DEFAULT 0,
            extra TEXT
        );

        -- 每会话对话数（真实用户 prompt 行计数；path 为主键以支持截断重扫归零）
        CREATE TABLE IF NOT EXISTS session_stats (
            path TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            prompts INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_session_stats_session
            ON session_stats(session_id);

        -- 跨文件用量去重键（claude: requestId+message.id），按时间窗剪枝。
        -- record_id/output_tokens：流式重复行的 output 递增，
        -- 后见的更大值要回填到已记录的 usage_records 行
        CREATE TABLE IF NOT EXISTS dedup_keys (
            key TEXT PRIMARY KEY,
            ts REAL NOT NULL,
            record_id INTEGER,
            output_tokens INTEGER NOT NULL DEFAULT 0
        );
        """)
        try db.execute("PRAGMA user_version = \(version)")
    }
}
