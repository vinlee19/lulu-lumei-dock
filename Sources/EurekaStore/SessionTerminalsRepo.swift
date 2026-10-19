import EurekaKit
import Foundation

/// Session ↔ terminal binding repo: records which terminals each session has run in.
///
/// The composite primary key `(source, session_id, term_bundle, tty)` turns "resume in another terminal" into a new row naturally,
/// so history comes for free; repeated events in the same terminal only update `last_seen`.
/// Observed data (only capturable when events happen, not re-derivable from local files) → never DROPped on upgrade.
public final class SessionTerminalsRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    /// Persist one binding (upsert on the same key: first insert records first_seen, later ones
    /// only advance last_seen).
    ///
    /// `origin` is merged with MAX — lexicographically 'probe' > 'hook', so this explicitly picks "the more trustworthy one":
    /// once a hook has captured it precisely, later probe results never downgrade it.
    public func record(
        source: AgentSource, sessionId: String, binding: TerminalBinding, at: Date
    ) throws {
        guard !binding.isEmpty else { return }
        try db.run("""
        INSERT INTO session_terminals
            (source, session_id, term_app, term_bundle, tty, tmux_pane, origin, first_seen, last_seen)
        VALUES (?,?,?,?,?,?,?,?,?)
        ON CONFLICT(source, session_id, term_bundle, tty) DO UPDATE SET
            last_seen = MAX(last_seen, excluded.last_seen),
            term_app = COALESCE(excluded.term_app, term_app),
            tmux_pane = COALESCE(excluded.tmux_pane, tmux_pane),
            origin = CASE WHEN origin = 'hook' OR excluded.origin = 'hook'
                          THEN 'hook' ELSE excluded.origin END
        """, [
            .text(source.rawValue), .text(sessionId),
            binding.app.map { .text($0) } ?? .null,
            // Primary-key columns store an empty string rather than NULL — NULL in the primary key
            // makes upsert never match
            .text(binding.bundleId ?? ""),
            .text(binding.tty ?? ""),
            binding.tmuxPane.map { .text($0) } ?? .null,
            .text(binding.origin.rawValue), .date(at), .date(at),
        ])
    }

    /// Every binding of a session, most recently active first (for the detail page's "ran in N
    /// terminals")
    public func bindings(
        source: AgentSource, sessionId: String
    ) throws -> [(binding: TerminalBinding, firstSeen: Date, lastSeen: Date)] {
        try db.query("""
        SELECT term_app, term_bundle, tty, tmux_pane, origin, first_seen, last_seen
        FROM session_terminals
        WHERE source = ? AND session_id = ?
        ORDER BY last_seen DESC
        """, [.text(source.rawValue), .text(sessionId)]) { row in
            (
                binding: Self.binding(row),
                firstSeen: Date(timeIntervalSince1970: row.real(5)),
                lastSeen: Date(timeIntervalSince1970: row.real(6))
            )
        }
    }

    /// Most recent binding (the jump target)
    public func latest(source: AgentSource, sessionId: String) throws -> TerminalBinding? {
        try bindings(source: source, sessionId: sessionId).first?.binding
    }

    /// Fetch "each session's most recent binding" in bulk so the list page needs one query (instead
    /// of one per row). Keys are `AgentTask.key(source:sessionId:)`, matching how the UI identifies
    /// sessions.
    public func latestBySession(source: AgentSource? = nil) throws -> [String: TerminalBinding] {
        var sql = """
        SELECT source, session_id, term_app, term_bundle, tty, tmux_pane, origin, last_seen
        FROM session_terminals
        """
        var binds: [SQLiteValue] = []
        if let source {
            sql += " WHERE source = ?"
            binds.append(.text(source.rawValue))
        }
        sql += " ORDER BY last_seen ASC"  // Ascending → later writes overwrite earlier ones, leaving the newest
        var result: [String: TerminalBinding] = [:]
        let rows = try db.query(sql, binds) { row -> (String, TerminalBinding)? in
            guard let sourceRaw = row.text(0), let source = AgentSource(rawValue: sourceRaw),
                  let sessionId = row.text(1) else { return nil }
            return (
                AgentTask.key(source: source, sessionId: sessionId),
                TerminalBinding(
                    app: Self.blankToNil(row.text(2)), bundleId: Self.blankToNil(row.text(3)),
                    tty: Self.blankToNil(row.text(4)), tmuxPane: Self.blankToNil(row.text(5)),
                    origin: TerminalBinding.Origin(rawValue: row.text(6) ?? "") ?? .probe)
            )
        }
        for case let (key, binding)? in rows { result[key] = binding }
        return result
    }

    private static func binding(_ row: SQLiteRow) -> TerminalBinding {
        TerminalBinding(
            app: blankToNil(row.text(0)), bundleId: blankToNil(row.text(1)),
            tty: blankToNil(row.text(2)), tmuxPane: blankToNil(row.text(3)),
            origin: TerminalBinding.Origin(rawValue: row.text(4) ?? "") ?? .probe)
    }

    /// Primary-key columns are stored as empty strings instead of NULL; restore them to nil on read
    /// (otherwise isEmpty / display logic misjudges)
    private static func blankToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
