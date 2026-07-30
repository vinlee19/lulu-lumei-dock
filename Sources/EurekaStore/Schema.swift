import Foundation

enum Schema {
    /// v19：移除逐轮诊断（`turn_metrics` / `turn_files`）—— 诊断页与它的落库链路已删除，
    ///      两张表连同索引一起丢掉，不再随扫描重建。
    /// v18：Codex 会话 id 解析修复 —— 旧版 `CodexSessionIndexer.headInfo` 会被 resume 写入的
    ///      第二条 `session_meta` 覆盖 id，导致 `turn_metrics` / `fts_docs` 里 30 个会话的
    ///      `session_id` 指向别的会话（实测 97 个 codex 文件只有 91 个唯一 id）。
    ///      指纹未变不会自动重建，只能靠版本跳变强制重扫。
    /// v17：新增 turn_metrics + turn_files（逐轮诊断指标；已于 v19 移除）
    /// v16：修 session_terminals 主键含可空列导致 upsert 失效（见下方一次性重建）
    /// v15：新增 session_terminals（会话 ↔ 终端绑定；只能在事件发生时采集，不可重推导，升级不 DROP）
    /// v14：新增 limit_samples（限额百分比采样，预测打满时间用；观测数据不可重推导，升级不 DROP）
    /// v13：新增全文搜索三件套 transcript_fts（FTS5 trigram）/ fts_docs / fts_files（派生表，升级重建全量重索引）
    /// v12：tool_calls 增列 last_ts（最近调用时间）+ tokens（触发时 token，仅 Claude 有值），派生表升级重建
    /// v11：新增 audit_events（agent 操作审计流水，非派生表，升级不 DROP）
    /// v10：新增 tool_calls（技能/插件/子代理/工具调用计数，派生表，升级重建全量重扫）
    /// v9：新增 sync_runs（云端备份轮次历史 + 文件明细，非派生表，升级不 DROP）
    /// v8：新增 sync_state（云端备份状态，非派生表，升级不 DROP）
    /// v7：task_history 新增 session_started_at（会话最初开始时间，历史"开始时间"排序用）
    /// v6：新增 session_stats（每会话对话数），派生表重建全量重扫
    static let version: Int64 = 19

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
            DROP TABLE IF EXISTS transcript_fts;
            DROP TABLE IF EXISTS fts_docs;
            DROP TABLE IF EXISTS fts_files;
            DROP TABLE IF EXISTS turn_metrics;
            DROP TABLE IF EXISTS turn_files;
            """)
        }
        // v15 建的 session_terminals 主键含可空列，upsert 失效攒了重复行。该表尚未随任何
        // 版本发布，且内容会随后续事件重新累积 → 一次性重建。**只在 15→16 这一跳生效**，
        // 不进上面那串 DROP（那是给可重推导的派生表用的，本表仍属"升级不 DROP"）。
        if current == 15 {
            try db.execute("DROP TABLE IF EXISTS session_terminals;")
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

        -- 会话 ↔ 终端绑定：这个 session 在哪些终端里跑过（复合主键天然保留历史，
        -- 同一会话 resume 到别的终端就多一行；last_seen 最大的那条是跳转目标）。
        -- 只能在事件发生的那一刻采到（环境变量 / 运行中的进程），**不可由本地文件重推导**
        -- → 与 task_history 同待遇，升级绝不 DROP。
        -- origin: 'hook'（relay 读环境，准确）| 'probe'（按 cwd 匹配进程上溯，较粗）。
        -- term_bundle / tty 参与主键，故必须 NOT NULL DEFAULT ''：
        -- SQLite 里 NULL != NULL，可空列进主键会让 upsert 永不命中 → 每个事件插一行。
        -- （实测踩过：Claude Code 跑在 IDE 里时既没有 TERM_PROGRAM 也没有控制终端，
        --  两列全空，同一会话瞬间攒出十几条重复行。）读出时空串再转回 nil。
        CREATE TABLE IF NOT EXISTS session_terminals (
            source TEXT NOT NULL,
            session_id TEXT NOT NULL,
            term_app TEXT,
            term_bundle TEXT NOT NULL DEFAULT '',
            tty TEXT NOT NULL DEFAULT '',
            tmux_pane TEXT,
            origin TEXT NOT NULL,
            first_seen REAL NOT NULL,
            last_seen REAL NOT NULL,
            PRIMARY KEY (source, session_id, term_bundle, tty)
        );
        CREATE INDEX IF NOT EXISTS idx_session_terminals_session
            ON session_terminals(source, session_id, last_seen DESC);

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

        -- 跨会话全文搜索（派生表，可由 transcript 重扫恢复，升级重建）。
        -- trigram 分词：中文/英文都按子串匹配（unicode61 不切 CJK，中文查询会失效）。
        -- transcript_fts.rowid == fts_docs.id（写入两表时对齐）。
        CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts USING fts5(text, tokenize='trigram');
        CREATE TABLE IF NOT EXISTS fts_docs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL,
            session_id TEXT NOT NULL,
            path TEXT NOT NULL,
            message_idx INTEGER NOT NULL,
            role TEXT NOT NULL,
            ts REAL
        );
        CREATE INDEX IF NOT EXISTS idx_fts_docs_path ON fts_docs(path);

        -- 已索引文件指纹（size+mtime 变更即整文件重建 docs；截断/改写天然覆盖）
        CREATE TABLE IF NOT EXISTS fts_files (
            path TEXT PRIMARY KEY,
            size INTEGER NOT NULL,
            mtime REAL NOT NULL
        );

        -- 限额百分比采样（每次限额刷新一行；预测"何时打满"用）。
        -- 观测数据不可本地重推导 → 升级不 DROP；保留 14 天由服务定期清理。
        CREATE TABLE IF NOT EXISTS limit_samples (
            ts REAL NOT NULL,
            source TEXT NOT NULL,
            window TEXT NOT NULL,
            percent REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_limit_samples
            ON limit_samples(source, window, ts);
        """)

        // task_history 不参与 drop/重建（真实历史），旧库补列走幂等 ALTER
        try addColumnIfMissing(db, table: "task_history", column: "session_started_at", type: "REAL")
        // sync_state 也是事实表（记录远端已有什么），同样只补列不重建。
        // category 是备份构成分两级展示的依据；老行为 NULL → 回退按 remote_key 解析。
        try addColumnIfMissing(db, table: "sync_state", column: "category", type: "TEXT")

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
