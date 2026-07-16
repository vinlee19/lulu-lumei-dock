import Foundation

enum Schema {
    /// v12：tool_calls 增列 last_ts（最近调用时间）+ tokens（触发时 token，仅 Claude 有值），派生表升级重建
    /// v11：新增 audit_events（agent 操作审计流水，非派生表，升级不 DROP）
    /// v10：新增 tool_calls（技能/插件/子代理/工具调用计数，派生表，升级重建全量重扫）
    /// v9：新增 sync_runs（云端备份轮次历史 + 文件明细，非派生表，升级不 DROP）
    /// v8：新增 sync_state（云端备份状态，非派生表，升级不 DROP）
    /// v7：task_history 新增 session_started_at（会话最初开始时间，历史"开始时间"排序用）
    /// v6：新增 session_stats（每会话对话数），派生表重建全量重扫
    static let version: Int64 = 12

    static func migrate(_ db: SQLiteDB) throws {
        let current = (try? db.query("PRAGMA user_version") { $0.int(0) }.first) ?? 0
        if current < version {
            // 用量派生表全部可由本地 transcript/rollout 重扫派生 → 结构变更直接重建，
            // 下轮扫描自动恢复（task_history / sync_state / sync_runs 记录真实事实，绝不 DROP）
            try db.execute("""
            DROP TABLE IF EXISTS dedup_keys;
            DROP TABLE IF EXISTS scan_files;
            DROP TABLE IF EXISTS usage_records;
            DROP TABLE IF EXISTS session_stats;
            DROP TABLE IF EXISTS tool_calls;
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
            session_started_at REAL,
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

        -- 工具/技能/插件/子代理调用计数（按日聚合，派生表：可由 transcript 重扫恢复，升级重建）
        -- last_ts：该日该项最近一次调用时间（unix epoch）；tokens：触发时 token 累计（仅 Claude 有值，其余 0）
        CREATE TABLE IF NOT EXISTS tool_calls (
            day TEXT NOT NULL,
            source TEXT NOT NULL,
            kind TEXT NOT NULL,
            name TEXT NOT NULL,
            count INTEGER NOT NULL DEFAULT 0,
            last_ts REAL NOT NULL DEFAULT 0,
            tokens INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (day, source, kind, name)
        );
        CREATE INDEX IF NOT EXISTS idx_tool_calls_day ON tool_calls(day);

        -- 云端备份状态：path → 最近一次成功上传时的本地指纹（size+mtime）。
        -- 记录的是远端事实、不可本地重推导 → 与 task_history 同待遇，升级不 DROP。
        CREATE TABLE IF NOT EXISTS sync_state (
            path TEXT PRIMARY KEY,
            remote_key TEXT NOT NULL,
            size INTEGER NOT NULL,
            mtime REAL NOT NULL,
            etag TEXT,
            uploaded_at REAL NOT NULL
        );

        -- 云端备份轮次历史（真实事实、升级不 DROP）：每轮一条 + 文件明细 JSON。
        CREATE TABLE IF NOT EXISTS sync_runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            uploaded INTEGER NOT NULL,
            uploaded_bytes INTEGER NOT NULL,
            failed INTEGER NOT NULL,
            deferred INTEGER NOT NULL,
            error TEXT,
            files TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_sync_runs_ts ON sync_runs(ts DESC);

        -- agent 操作审计流水：每次工具调用一行（命令/文件路径全文，无输出正文）。
        -- hook payload 消费即删、不可本地重推导 → 与 task_history 同待遇，升级绝不 DROP。
        -- op_id：Claude tool_use_id / Codex call_id / 合成 hash；(source,session_id,op_id) 唯一 → INSERT OR IGNORE 幂等。
        CREATE TABLE IF NOT EXISTS audit_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            op_id TEXT NOT NULL,
            source TEXT NOT NULL,
            session_id TEXT NOT NULL,
            ts REAL NOT NULL,
            kind TEXT NOT NULL,
            tool TEXT NOT NULL,
            detail TEXT NOT NULL,
            cwd TEXT,
            exit_code INTEGER,
            is_error INTEGER NOT NULL DEFAULT 0,
            risk_level INTEGER NOT NULL DEFAULT 0,
            risk_rule TEXT,
            UNIQUE(source, session_id, op_id)
        );
        CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_events(ts DESC);
        CREATE INDEX IF NOT EXISTS idx_audit_session ON audit_events(session_id);
        CREATE INDEX IF NOT EXISTS idx_audit_risk ON audit_events(risk_level) WHERE risk_level > 0;
        """)

        // task_history 不参与 drop/重建（真实历史），旧库补列走幂等 ALTER
        try addColumnIfMissing(db, table: "task_history", column: "session_started_at", type: "REAL")

        try db.execute("PRAGMA user_version = \(version)")
    }

    /// 幂等加列：仅当 table 不含该列时 ALTER，安全用于全新库与升级库
    private static func addColumnIfMissing(
        _ db: SQLiteDB, table: String, column: String, type: String
    ) throws {
        let existing = try db.query("PRAGMA table_info(\(table))") { $0.text(1) }
        guard !existing.contains(column) else { return }
        try db.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
    }
}
