import Foundation

/// 全文命中：一条消息级的搜索结果（snippet 由调用层按原文裁剪）
public struct TranscriptSearchHit: Equatable {
    public var docId: Int64
    public var source: String
    public var sessionId: String
    public var path: String
    public var messageIdx: Int
    public var role: String
    public var ts: Date?
    /// 命中消息全文（已按索引截断上限存储）
    public var text: String
}

/// 待索引的一条消息文档
public struct TranscriptSearchDoc {
    public var messageIdx: Int
    public var role: String
    public var ts: Date?
    public var text: String

    public init(messageIdx: Int, role: String, ts: Date?, text: String) {
        self.messageIdx = messageIdx
        self.role = role
        self.ts = ts
        self.text = text
    }
}

/// 跨会话全文搜索仓库：transcript_fts（FTS5 trigram）+ fts_docs + fts_files。
/// 派生数据：清空/重建随时安全，下轮索引自动恢复。
public final class SearchRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    // MARK: - 文件指纹

    /// 全部已索引文件的指纹（path → (size, mtime)），一次取回做增量比对
    public func fileFingerprints() throws -> [String: (size: Int64, mtime: Double)] {
        let rows = try db.query("SELECT path, size, mtime FROM fts_files") { row in
            (row.text(0) ?? "", row.int(1), row.real(2))
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.0, (size: $0.1, mtime: $0.2)) })
    }

    // MARK: - 写入

    /// 整文件重建：删旧 docs → 插新 docs → 记指纹，单事务保证一致
    public func replaceDocs(
        path: String, source: String, sessionId: String,
        size: Int64, mtime: Double, docs: [TranscriptSearchDoc]
    ) throws {
        try db.transaction {
            try deleteDocs(path: path)
            for doc in docs {
                try db.run("""
                INSERT INTO fts_docs (source, session_id, path, message_idx, role, ts)
                VALUES (?,?,?,?,?,?)
                """, [
                    .text(source), .text(sessionId), .text(path),
                    .int(Int64(doc.messageIdx)), .text(doc.role), .date(doc.ts),
                ])
                let rowid = db.lastInsertRowID
                try db.run(
                    "INSERT INTO transcript_fts (rowid, text) VALUES (?,?)",
                    [.int(rowid), .text(doc.text)])
            }
            try db.run(
                "INSERT OR REPLACE INTO fts_files (path, size, mtime) VALUES (?,?,?)",
                [.text(path), .int(size), .real(mtime)])
        }
    }

    /// 清理已消失的文件（transcript 被删除/移走）
    public func prune(keeping existingPaths: Set<String>) throws {
        let indexed = try db.query("SELECT path FROM fts_files") { $0.text(0) ?? "" }
        for path in indexed where !existingPaths.contains(path) {
            try db.transaction {
                try deleteDocs(path: path)
                try db.run("DELETE FROM fts_files WHERE path = ?", [.text(path)])
            }
        }
    }

    /// 清空全部索引（设置页「清空全文索引」）
    public func clearAll() throws {
        try db.execute("""
        DELETE FROM transcript_fts;
        DELETE FROM fts_docs;
        DELETE FROM fts_files;
        """)
    }

    private func deleteDocs(path: String) throws {
        try db.run(
            "DELETE FROM transcript_fts WHERE rowid IN (SELECT id FROM fts_docs WHERE path = ?)",
            [.text(path)])
        try db.run("DELETE FROM fts_docs WHERE path = ?", [.text(path)])
    }

    // MARK: - 查询

    /// 全文检索：≥3 字符走 trigram MATCH（子串语义，中英文一致）；
    /// 2 字符退化为 LIKE 全扫（有上限，中文双字词常见，不能不支持）；<2 字符返回空。
    public func search(_ rawQuery: String, limit: Int = 50) throws -> [TranscriptSearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        if query.count >= 3 {
            // 整体作为一个短语（双引号内的 " 翻倍转义），trigram 下即子串匹配
            let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return try db.query("""
            SELECT d.id, d.source, d.session_id, d.path, d.message_idx, d.role, d.ts, f.text
            FROM transcript_fts f JOIN fts_docs d ON d.id = f.rowid
            WHERE transcript_fts MATCH ?
            ORDER BY d.ts DESC LIMIT ?
            """, [.text(phrase), .int(Int64(limit))], map: Self.hitMapper)
        }
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try db.query("""
        SELECT d.id, d.source, d.session_id, d.path, d.message_idx, d.role, d.ts, f.text
        FROM transcript_fts f JOIN fts_docs d ON d.id = f.rowid
        WHERE f.text LIKE ? ESCAPE '\\'
        ORDER BY d.ts DESC LIMIT ?
        """, [.text("%\(escaped)%"), .int(Int64(limit))], map: Self.hitMapper)
    }

    private static let hitMapper: (SQLiteRow) -> TranscriptSearchHit = { row in
        TranscriptSearchHit(
            docId: row.int(0),
            source: row.text(1) ?? "",
            sessionId: row.text(2) ?? "",
            path: row.text(3) ?? "",
            messageIdx: Int(row.int(4)),
            role: row.text(5) ?? "",
            ts: row.date(6),
            text: row.text(7) ?? "")
    }

    /// 索引文档总数（设置页展示 / 测试断言）
    public func docCount() throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM fts_docs") { $0.int(0) }.first ?? 0)
    }
}
