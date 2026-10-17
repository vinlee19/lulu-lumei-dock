import Foundation

/// Knowledge-surface full-text hit: one file-level search result
public struct KnowledgeSearchHit: Equatable {
    public var kind: String       // skill / memory / instruction / plan
    public var path: String
    public var source: String
    public var title: String
    public var project: String?
    /// Matched body (stored truncated to the index cap; the caller trims the snippet)
    public var text: String
}

/// Knowledge-surface full-text search repo: knowledge_fts (FTS5 trigram) + knowledge_docs.
/// Derived data: clearing/rebuilding is always safe; the next knowledge-surface scan restores it.
public final class KnowledgeSearchRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    /// Fingerprints of every indexed file (path → (size, mtime)), fetched in one go for incremental
    /// comparison
    public func fileFingerprints() throws -> [String: (size: Int64, mtime: Double)] {
        let rows = try db.query("SELECT path, size, mtime FROM knowledge_docs") { row in
            (row.text(0) ?? "", row.int(1), row.real(2))
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.0, (size: $0.1, mtime: $0.2)) })
    }

    /// Rebuild one file: delete old → insert new, in one transaction so fts and docs stay aligned
    public func replaceDoc(
        path: String, kind: String, source: String, title: String,
        project: String?, size: Int64, mtime: Double, body: String
    ) throws {
        try db.transaction {
            try deleteDoc(path: path)
            try db.run("""
            INSERT INTO knowledge_docs (kind, path, source, title, project, size, mtime)
            VALUES (?,?,?,?,?,?,?)
            """, [
                .text(kind), .text(path), .text(source), .text(title),
                project.map { .text($0) } ?? .null, .int(size), .real(mtime),
            ])
            let rowid = db.lastInsertRowID
            try db.run(
                "INSERT INTO knowledge_fts (rowid, text) VALUES (?,?)",
                [.int(rowid), .text(body)])
        }
    }

    /// Clear the whole index (Settings' "clear full-text index" should cover the knowledge-surface
    /// index too). Wrapped in a transaction: symmetric with replaceDoc's promise to keep fts/docs
    /// aligned, so a write from another connection can't land between the two DELETEs and leave
    /// orphan rows.
    public func clearAll() throws {
        try db.transaction {
            try db.execute("""
            DELETE FROM knowledge_fts;
            DELETE FROM knowledge_docs;
            """)
        }
    }

    /// Clean up files that vanished. prompt entries (kind = "prompt", whose path holds a prompt id
    /// rather than a file path) are managed separately by prunePrompts — touching them here would
    /// treat the prompt id as a file path and delete it by mistake.
    public func prune(keeping existingPaths: Set<String>) throws {
        let indexed = try db.query(
            "SELECT path FROM knowledge_docs WHERE kind != 'prompt'"
        ) { $0.text(0) ?? "" }
        for path in indexed where !existingPaths.contains(path) {
            try db.transaction { try deleteDoc(path: path) }
        }
    }

    /// Cleanup for prompt entries only (keeping = the set of prompt ids that still exist)
    public func prunePrompts(keeping existingIds: Set<String>) throws {
        let indexed = try db.query(
            "SELECT path FROM knowledge_docs WHERE kind = 'prompt'"
        ) { $0.text(0) ?? "" }
        for path in indexed where !existingIds.contains(path) {
            try db.transaction { try deleteDoc(path: path) }
        }
    }

    private func deleteDoc(path: String) throws {
        try db.run(
            "DELETE FROM knowledge_fts WHERE rowid IN (SELECT id FROM knowledge_docs WHERE path = ?)",
            [.text(path)])
        try db.run("DELETE FROM knowledge_docs WHERE path = ?", [.text(path)])
    }

    /// Full-text search: ≥3 characters use trigram MATCH; 2 characters fall back to LIKE (same
    /// strategy as SearchRepo)
    public func search(_ rawQuery: String, limit: Int = 30) throws -> [KnowledgeSearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        if query.count >= 3 {
            let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return try db.query("""
            SELECT d.kind, d.path, d.source, d.title, d.project, f.text
            FROM knowledge_fts f JOIN knowledge_docs d ON d.id = f.rowid
            WHERE knowledge_fts MATCH ?
            ORDER BY d.mtime DESC LIMIT ?
            """, [.text(phrase), .int(Int64(limit))], map: Self.hitMapper)
        }
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try db.query("""
        SELECT d.kind, d.path, d.source, d.title, d.project, f.text
        FROM knowledge_fts f JOIN knowledge_docs d ON d.id = f.rowid
        WHERE f.text LIKE ? ESCAPE '\\'
        ORDER BY d.mtime DESC LIMIT ?
        """, [.text("%\(escaped)%"), .int(Int64(limit))], map: Self.hitMapper)
    }

    private static let hitMapper: (SQLiteRow) -> KnowledgeSearchHit = { row in
        KnowledgeSearchHit(
            kind: row.text(0) ?? "", path: row.text(1) ?? "", source: row.text(2) ?? "",
            title: row.text(3) ?? "", project: row.text(4), text: row.text(5) ?? "")
    }
}
