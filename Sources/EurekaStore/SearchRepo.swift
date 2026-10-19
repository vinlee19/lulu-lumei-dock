import Foundation

/// Full-text hit: one message-level search result (the caller trims the snippet from the original
/// text)
public struct TranscriptSearchHit: Equatable {
    public var docId: Int64
    public var source: String
    public var sessionId: String
    public var path: String
    public var messageIdx: Int
    public var role: String
    public var ts: Date?
    /// Full text of the matched message (stored truncated to the index cap)
    public var text: String
}

/// One message document to index
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

/// Cross-session full-text search repo: transcript_fts (FTS5 trigram) + fts_docs + fts_files.
/// Derived data: clearing/rebuilding is always safe; the next indexing pass restores it.
public final class SearchRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    // MARK: - File fingerprints

    /// Fingerprints of every indexed file (path → (size, mtime)), fetched in one go for incremental
    /// comparison
    public func fileFingerprints() throws -> [String: (size: Int64, mtime: Double)] {
        let rows = try db.query("SELECT path, size, mtime FROM fts_files") { row in
            (row.text(0) ?? "", row.int(1), row.real(2))
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.0, (size: $0.1, mtime: $0.2)) })
    }

    // MARK: - Writes

    /// Rebuild a whole file: delete old docs → insert new docs → record the fingerprint, in one
    /// transaction for consistency
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

    /// Clean up files that vanished (transcript deleted/moved)
    public func prune(keeping existingPaths: Set<String>) throws {
        let indexed = try db.query("SELECT path FROM fts_files") { $0.text(0) ?? "" }
        for path in indexed where !existingPaths.contains(path) {
            try db.transaction {
                try deleteDocs(path: path)
                try db.run("DELETE FROM fts_files WHERE path = ?", [.text(path)])
            }
        }
    }

    /// Clear the whole index (Settings' "clear full-text index")
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

    // MARK: - Queries

    /// Full-text search: ≥3 characters use trigram MATCH (substring semantics, same for Chinese and
    /// English); 2 characters fall back to a capped LIKE full scan (two-character Chinese words are
    /// common, so this must be supported); <2 characters return nothing.
    public func search(_ rawQuery: String, limit: Int = 50) throws -> [TranscriptSearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        if query.count >= 3 {
            // The whole query as one phrase (" inside double quotes escaped by doubling); under
            // trigram that's a substring match
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

    /// Total indexed documents (shown in Settings / used in test assertions)
    public func docCount() throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM fts_docs") { $0.int(0) }.first ?? 0)
    }
}
