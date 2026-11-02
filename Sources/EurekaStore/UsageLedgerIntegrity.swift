import EurekaKit
import Foundation

/// What opening the store did to the usage ledger's uniqueness guarantee.
public enum UsageLedgerRepair: Equatable, Sendable {
    /// The unique record index already existed (every open after the first)
    case alreadyEnforced
    /// The index was created; `removedRows` copies were deleted and every row of their groups was
    /// copied to `usage_records_dedup_backup` first (0 on a fresh or clean ledger)
    case enforced(removedRows: Int)
    /// The repair was rolled back and the ledger left untouched; the next open retries it
    case failed(String)
}

/// Keeps one usage record per request in `usage_records`, whatever the scanners re-read.
///
/// Scanners only remember how far they read (`scan_files`: path, inode, offset). When that state
/// is lost they read the file from the start again: a source rewrites the file (Codex compresses a
/// rollout to `.jsonl.zst` and decompresses it on resume, so the path comes back with a new
/// inode), or a Claude/Gemini/Qwen dedup key ages out after 8 days. Every row was then inserted
/// again. Measured on one install (2026-10-30): 59,173 of 151,882 rows were exact copies, all-time
/// tokens read 34.45B for 23.89B real, Codex 2.17x.
///
/// Some copies don't even share the timestamp ("near copies", see `nearCopyWindows`), so a record
/// is the same request either by exact key (enforced by a unique index) or by identical token
/// counts within a per-source window.
///
/// The ledger is a fact table, not a derived one: agents delete or compress their source files, so
/// a rebuild by rescanning (a `Schema.version` bump) would lose that history for good. Existing
/// installs are therefore repaired in place, once, and later re-reads become no-ops.
public enum UsageLedgerIntegrity {
    static let indexName = "idx_usage_record_key"
    static let backupTable = "usage_records_dedup_backup"

    /// A record's identity: every column a scanner derives from the source line, except
    /// `output_tokens` (Claude backfills it while a reply streams) and the pricing columns
    /// (`provider` is learned later by some scanners). An API call is told apart by its own
    /// timestamp, so two real requests never share all of these. `session_id` goes through
    /// COALESCE because NULLs never collide in a unique index.
    static let keyExpressions = [
        "source", "COALESCE(session_id, '')", "model", "ts",
        "input_tokens", "cache_creation_tokens", "cache_read_tokens",
    ]

    /// How far apart two rows of a source may be stamped and still be one request when every token
    /// count, output included, is identical. Only sources whose copies were seen re-stamped:
    /// - Codex rewrote its old rollouts once (2026-09-08) and gave replayed events the time of the
    ///   rewrite: 8,279 copies up to a day off, none further. Among 26k real events no two of a
    ///   session share all token counts, even 30 days apart.
    /// - Claude writes one message as several lines up to 374 s apart (44k requests); a row read
    ///   mid-stream and a later re-read were stamped with different lines of it. 1 real pair of
    ///   parallel subagent requests shares every count within 6 s (kept apart while recent, see
    ///   `ClaudeTranscriptScanner`).
    public static let nearCopyWindows: [AgentSource: TimeInterval] = [.codex: 86_400, .claude: 600]

    /// `WHERE` clause matching one record's key; bind with `keyBindings(record, ts: [ts])`
    static let keyPredicate = predicate(ts: "ts = ?")
    /// Same request with a stamp anywhere in a range; bind with `sameRequestBindings(record, ...)`
    static let sameRequestPredicate = predicate(ts: "ts BETWEEN ? AND ?") + " AND output_tokens = ?"

    private static func predicate(ts: String) -> String {
        keyExpressions.map { $0 == "ts" ? ts : "\($0) = ?" }.joined(separator: " AND ")
    }

    /// Bindings in `keyExpressions` order, with `ts` standing for the timestamp placeholder(s)
    static func keyBindings(_ record: UsageRecord, ts: [Date]) -> [SQLiteValue] {
        [.text(record.source.rawValue), .text(record.sessionId ?? ""), .text(record.model)]
            + ts.map { .real($0.timeIntervalSince1970) }
            + [
                .int(Int64(record.inputTokens)), .int(Int64(record.cacheCreationTokens)),
                .int(Int64(record.cacheReadTokens)),
            ]
    }

    static func sameRequestBindings(_ record: UsageRecord, within span: ClosedRange<Date>)
        -> [SQLiteValue]
    {
        keyBindings(record, ts: [span.lowerBound, span.upperBound])
            + [.int(Int64(record.outputTokens))]
    }

    /// Runs on every connection open, after the schema is in place. The index's existence is the
    /// "already done" marker; the repair and the index are one write transaction that re-checks
    /// it, so of several connections opening at once exactly one repairs.
    static func enforce(_ db: SQLiteDB) -> UsageLedgerRepair {
        guard !indexExists(db) else { return .alreadyEnforced }
        var outcome = UsageLedgerRepair.alreadyEnforced
        do {
            try db.transaction {
                guard !indexExists(db) else { return }
                let removed = try collapse(db, groups: exactCopies)
                    + collapse(db, groups: nearCopies)
                try db.execute("""
                CREATE UNIQUE INDEX \(indexName)
                    ON usage_records(\(keyExpressions.joined(separator: ", ")))
                """)
                outcome = .enforced(removedRows: removed)
            }
        } catch {
            NSLog("%@", "UsageLedgerIntegrity: repair rolled back, retrying on next open: \(error)")
            return .failed(String(describing: error))
        }
        if case .enforced(let removed) = outcome, removed > 0 {
            NSLog("%@", "UsageLedgerIntegrity: removed \(removed) duplicate usage rows (copies in \(backupTable))")
        }
        return outcome
    }

    private static func indexExists(_ db: SQLiteDB) -> Bool {
        ((try? db.query(
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
            [.text(indexName)]) { _ in true }) ?? []).isEmpty == false
    }

    /// Rows sharing a full key. Selects, per row of usage_records, the columns `collapse` needs.
    private static var exactCopies: String {
        """
        SELECT id,
               MIN(id) OVER g AS kept_id, COUNT(*) OVER g AS copies,
               MAX(output_tokens) OVER g AS max_output,
               MAX(cache_creation_1h_tokens) OVER g AS max_1h,
               MAX(provider) OVER g AS any_provider,
               MAX(reported_cost_usd) OVER g AS any_cost
        FROM usage_records
        WINDOW g AS (PARTITION BY \(keyExpressions.joined(separator: ", ")))
        """
    }

    /// Rows with identical token counts (output included) whose stamps lie within their source's
    /// `nearCopyWindows` span of the previous one. A run of such rows is one group.
    private static var nearCopies: String {
        let spans = nearCopyWindows
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "('\($0.key.rawValue)', \($0.value))" }
            .joined(separator: ", ")
        let tokens = """
            source, COALESCE(session_id, ''), model, input_tokens, output_tokens,
            cache_creation_tokens, cache_read_tokens
            """
        return """
        WITH spans(source, span) AS (VALUES \(spans)),
        ordered AS (
            SELECT u.*, s.span, u.ts - LAG(u.ts) OVER (PARTITION BY \(tokens) ORDER BY ts, id) AS gap
            FROM usage_records u JOIN spans s USING (source)
        ),
        runs AS (
            SELECT *, SUM(gap IS NULL OR gap > span) OVER (
                PARTITION BY \(tokens) ORDER BY ts, id) AS run
            FROM ordered
        )
        SELECT id,
               MIN(id) OVER g AS kept_id, COUNT(*) OVER g AS copies,
               MAX(output_tokens) OVER g AS max_output,
               MAX(cache_creation_1h_tokens) OVER g AS max_1h,
               MAX(provider) OVER g AS any_provider,
               MAX(reported_cost_usd) OVER g AS any_cost
        FROM runs
        WINDOW g AS (PARTITION BY \(tokens), run)
        """
    }

    /// Keeps the oldest row of each group from `groups`, lifted to the group's largest output and
    /// first known provider / reported cost, and deletes the rest. Every row of an affected group
    /// is copied to the backup table first (once: a row is snapshot before its first change),
    /// inside the caller's transaction, so the deletion is never committed without its copy and
    /// can be undone by re-inserting the backup's rows. Returns the number of deleted rows.
    private static func collapse(_ db: SQLiteDB, groups: String) throws -> Int {
        try db.execute("""
        DROP TABLE IF EXISTS temp.usage_dup_rows;
        CREATE TEMP TABLE usage_dup_rows AS
        SELECT id, kept_id, max_output, max_1h, any_provider, any_cost
        FROM (\(groups))
        WHERE copies > 1;
        """)
        let removed = try db.query(
            "SELECT COUNT(*) FROM temp.usage_dup_rows WHERE id != kept_id") { Int($0.int(0)) }
            .first ?? 0
        if removed > 0 {
            // A fact table like task_history: it holds the only copy of the deleted rows, so it is
            // never in Schema's DROP list. It can be dropped once the repaired totals have shipped
            // for a release without complaints.
            try db.execute("""
            CREATE TABLE IF NOT EXISTS \(backupTable) (
                id INTEGER NOT NULL,
                source TEXT NOT NULL,
                model TEXT NOT NULL,
                project TEXT,
                session_id TEXT,
                ts REAL NOT NULL,
                input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                cache_creation_tokens INTEGER NOT NULL,
                cache_creation_1h_tokens INTEGER NOT NULL,
                cache_read_tokens INTEGER NOT NULL,
                provider TEXT,
                reported_cost_usd REAL,
                kept INTEGER NOT NULL,
                backed_up_at REAL NOT NULL
            );
            """)
            try db.run("""
            INSERT INTO \(backupTable)
            SELECT u.id, u.source, u.model, u.project, u.session_id, u.ts,
                   u.input_tokens, u.output_tokens, u.cache_creation_tokens,
                   u.cache_creation_1h_tokens, u.cache_read_tokens, u.provider,
                   u.reported_cost_usd, d.id = d.kept_id, ?
            FROM usage_records u JOIN temp.usage_dup_rows d ON d.id = u.id
            WHERE u.id NOT IN (SELECT id FROM \(backupTable))
            """, [.real(Date().timeIntervalSince1970)])
            try db.execute("""
            -- A row an earlier pass kept (already snapshot) can be a copy for this one
            UPDATE \(backupTable) SET kept = 0
            WHERE id IN (SELECT id FROM temp.usage_dup_rows WHERE id != kept_id);
            """)
            try db.execute("""
            UPDATE usage_records
            SET output_tokens = d.max_output,
                cache_creation_1h_tokens = d.max_1h,
                provider = COALESCE(usage_records.provider, d.any_provider),
                reported_cost_usd = COALESCE(usage_records.reported_cost_usd, d.any_cost)
            FROM temp.usage_dup_rows d
            WHERE d.id = usage_records.id AND d.id = d.kept_id;

            -- Claude backfills output through the record id its dedup key remembers
            UPDATE dedup_keys
            SET record_id = (
                SELECT kept_id FROM temp.usage_dup_rows d WHERE d.id = dedup_keys.record_id)
            WHERE record_id IN (SELECT id FROM temp.usage_dup_rows WHERE id != kept_id);

            DELETE FROM usage_records
            WHERE id IN (SELECT id FROM temp.usage_dup_rows WHERE id != kept_id);
            """)
        }
        try db.execute("DROP TABLE temp.usage_dup_rows")
        return removed
    }
}
