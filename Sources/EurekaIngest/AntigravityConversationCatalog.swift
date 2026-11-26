import EurekaStore
import Foundation

/// What Antigravity's own `conversation_summaries.db` files say about each conversation.
///
/// The CLI and the IDE each keep one (`AntigravityPaths.summaryDatabases()`). Both list every
/// conversation of both apps (title, preview = first prompt, step count, workspace), but only the
/// CLI copy has titles filled in, so the two are merged field by field. Each also holds an FTS5
/// index (`conversations_fts`) of the user and agent text of its own app's conversations, chunked,
/// with `[[step, utf8 byte offset], …]` maps into the chunk bodies. That index is the only readable
/// text of IDE conversations, whose `.pb` files are encrypted and which have no transcript jsonl.
///
/// The databases are in WAL mode and read through `SQLiteWALSnapshot` (a copy, never the live
/// file); results are cached until a database's size or mtime changes.
public final class AntigravityConversationCatalog: @unchecked Sendable {
    public struct Summary: Equatable, Sendable {
        public var id: String
        public var title: String?
        public var preview: String?
        public var stepCount: Int
        public var lastModified: Date?
        public var cwd: String?

        /// Title, else the first line of the first prompt (clipped)
        public var displayName: String? {
            if let title, !title.isEmpty { return title }
            guard let line = preview?.split(whereSeparator: \.isNewline).first
                .map({ $0.trimmingCharacters(in: .whitespaces) }), !line.isEmpty
            else { return nil }
            return line.count > 80 ? String(line.prefix(80)) + "…" : line
        }
    }

    /// One user or agent turn recovered from the FTS index
    public struct Segment: Equatable, Sendable {
        public var step: Int
        public var isUser: Bool
        public var text: String
    }

    public static let shared = AntigravityConversationCatalog(
        databases: { AntigravityPaths.summaryDatabases() })

    private let databases: () -> [URL]
    private let lock = NSLock()
    private var fingerprints: [String: SQLiteWALSnapshot.Fingerprint] = [:]
    private var cachedSummaries: [String: Summary] = [:]
    private var cachedSegments: [String: [Segment]] = [:]

    public init(databases: @escaping () -> [URL]) {
        self.databases = databases
    }

    /// Every conversation known to either summary database, keyed by conversation id
    public func summaries() -> [String: Summary] {
        refreshIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return cachedSummaries
    }

    /// The conversation's user / agent text from the FTS index, in step order; nil when neither
    /// database indexed it
    public func segments(conversationId: String) -> [Segment]? {
        refreshIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return cachedSegments[conversationId]
    }

    // MARK: - Loading

    private func refreshIfNeeded() {
        let urls = databases()
        var current: [String: SQLiteWALSnapshot.Fingerprint] = [:]
        for url in urls {
            if let fingerprint = SQLiteWALSnapshot.fingerprint(url) { current[url.path] = fingerprint }
        }
        lock.lock()
        let unchanged = current == fingerprints
        lock.unlock()
        guard !unchanged else { return }

        var summaries: [String: Summary] = [:]
        var segments: [String: [Segment]] = [:]
        for url in urls where current[url.path] != nil {
            SQLiteWALSnapshot.read(url) { db in
                for summary in try Self.readSummaries(db) {
                    summaries[summary.id] = Self.merge(summaries[summary.id], summary)
                }
                for (id, found) in try Self.readSegments(db) where segments[id] == nil {
                    segments[id] = found
                }
            }
        }
        lock.lock()
        fingerprints = current
        cachedSummaries = summaries
        cachedSegments = segments
        lock.unlock()
    }

    static func merge(_ old: Summary?, _ new: Summary) -> Summary {
        guard var merged = old else { return new }
        if merged.title?.isEmpty ?? true { merged.title = new.title }
        if merged.preview?.isEmpty ?? true { merged.preview = new.preview }
        merged.stepCount = max(merged.stepCount, new.stepCount)
        merged.lastModified = [merged.lastModified, new.lastModified].compactMap { $0 }.max()
        if merged.cwd == nil { merged.cwd = new.cwd }
        return merged
    }

    static func readSummaries(_ db: SQLiteDB) throws -> [Summary] {
        guard db.tableExists("conversation_summaries") else { return [] }
        // last_modified_time is text like "2026-11-25 10:28:38.222336+00:00"; julianday parses it
        // (unset rows hold year 0001, filtered below)
        return try db.query("""
        SELECT conversation_id, title, preview, step_count,
               (julianday(last_modified_time) - 2440587.5) * 86400.0, workspace_uris
        FROM conversation_summaries
        """) { row in
            let seconds = row.real(4)
            return Summary(
                id: row.text(0) ?? "",
                title: row.text(1).flatMap { $0.isEmpty ? nil : $0 },
                preview: row.text(2).flatMap { $0.isEmpty ? nil : $0 },
                stepCount: Int(row.int(3)),
                lastModified: seconds > 1_000_000_000 ? Date(timeIntervalSince1970: seconds) : nil,
                cwd: firstWorkspacePath(row.text(5)))
        }.filter { !$0.id.isEmpty }
    }

    /// `["file:///Users/me/repo", …]` → `/Users/me/repo`
    static func firstWorkspacePath(_ json: String?) -> String? {
        guard let data = json?.data(using: .utf8),
              let uris = (try? JSONSerialization.jsonObject(with: data)) as? [String],
              let first = uris.first(where: { $0.hasPrefix("file://") })
        else { return nil }
        return AntigravityPaths.uriToPath(first)
    }

    static func readSegments(_ db: SQLiteDB) throws -> [String: [Segment]] {
        guard db.tableExists("conversations_fts") else { return [:] }
        // chunk_index -1 is a per-conversation metadata row with empty bodies
        let rows = try db.query("""
        SELECT conversation_id, CAST(chunk_index AS INTEGER), user_step_byte_offsets,
               agent_step_byte_offsets, user_body, agent_body
        FROM conversations_fts
        WHERE CAST(chunk_index AS INTEGER) >= 0
        """) { row in
            (id: row.text(0) ?? "", chunk: row.int(1),
             userOffsets: row.text(2), agentOffsets: row.text(3),
             userBody: row.text(4) ?? "", agentBody: row.text(5) ?? "")
        }
        var result: [String: [Segment]] = [:]
        for row in rows.sorted(by: { ($0.id, $0.chunk) < ($1.id, $1.chunk) }) where !row.id.isEmpty {
            result[row.id, default: []] += slice(row.userBody, offsets: row.userOffsets, isUser: true)
            result[row.id, default: []] += slice(row.agentBody, offsets: row.agentOffsets, isUser: false)
        }
        return result.mapValues { segments in
            segments.enumerated()
                .sorted { ($0.element.step, $0.offset) < ($1.element.step, $1.offset) }
                .map(\.element)
        }
    }

    /// Cuts one chunk body at its `[[step, byteOffset], …]` map; each piece runs to the next offset
    static func slice(_ body: String, offsets json: String?, isUser: Bool) -> [Segment] {
        guard let data = json?.data(using: .utf8),
              let pairs = (try? JSONSerialization.jsonObject(with: data)) as? [[Int]]
        else { return [] }
        let bytes = Array(body.utf8)
        let marks = pairs.compactMap { pair -> (step: Int, offset: Int)? in
            guard pair.count == 2, pair[1] >= 0, pair[1] <= bytes.count else { return nil }
            return (pair[0], pair[1])
        }.sorted { $0.offset < $1.offset }
        var segments: [Segment] = []
        for (index, mark) in marks.enumerated() {
            let end = index + 1 < marks.count ? marks[index + 1].offset : bytes.count
            guard end > mark.offset else { continue }
            let text = String(decoding: bytes[mark.offset..<end], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(Segment(step: mark.step, isUser: isUser, text: text)) }
        }
        return segments
    }
}
