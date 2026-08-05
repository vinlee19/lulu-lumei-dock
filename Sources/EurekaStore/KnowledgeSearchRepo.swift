import Foundation

/// 知识面全文命中：一份文件级的搜索结果
public struct KnowledgeSearchHit: Equatable {
    public var kind: String       // skill / memory / instruction / plan
    public var path: String
    public var source: String
    public var title: String
    public var project: String?
    /// 命中正文（按索引截断上限存储；snippet 由调用层裁剪）
    public var text: String
}

/// 知识面全文搜索仓库：knowledge_fts（FTS5 trigram）+ knowledge_docs。
/// 派生数据：清空/重建随时安全，下轮知识面扫描自动恢复。
public final class KnowledgeSearchRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    /// 全部已索引文件的指纹（path → (size, mtime)），一次取回做增量比对
    public func fileFingerprints() throws -> [String: (size: Int64, mtime: Double)] {
        let rows = try db.query("SELECT path, size, mtime FROM knowledge_docs") { row in
            (row.text(0) ?? "", row.int(1), row.real(2))
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.0, (size: $0.1, mtime: $0.2)) })
    }

    /// 单文件重建：删旧 → 插新，单事务保证 fts 与 docs 对齐
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

    /// 清空全部索引（设置页「清空全文索引」应同时覆盖知识面索引）。
    /// 包一层事务：与 replaceDoc 对 fts/docs 两表对齐的承诺对称，防两条 DELETE 之间
    /// 被另一连接的写插入，留下孤儿行。
    public func clearAll() throws {
        try db.transaction {
            try db.execute("""
            DELETE FROM knowledge_fts;
            DELETE FROM knowledge_docs;
            """)
        }
    }

    /// 清理已消失的文件
    public func prune(keeping existingPaths: Set<String>) throws {
        let indexed = try db.query("SELECT path FROM knowledge_docs") { $0.text(0) ?? "" }
        for path in indexed where !existingPaths.contains(path) {
            try db.transaction { try deleteDoc(path: path) }
        }
    }

    private func deleteDoc(path: String) throws {
        try db.run(
            "DELETE FROM knowledge_fts WHERE rowid IN (SELECT id FROM knowledge_docs WHERE path = ?)",
            [.text(path)])
        try db.run("DELETE FROM knowledge_docs WHERE path = ?", [.text(path)])
    }

    /// 全文检索：≥3 字符 trigram MATCH；2 字符 LIKE 兜底（与 SearchRepo 同策略）
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
