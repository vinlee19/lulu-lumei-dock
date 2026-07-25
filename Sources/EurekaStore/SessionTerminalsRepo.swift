import EurekaKit
import Foundation

/// 会话 ↔ 终端绑定仓库：记录每个会话在哪些终端里跑过。
///
/// 复合主键 `(source, session_id, term_bundle, tty)` 让"换终端 resume"自然变成新的一行，
/// 于是历史免费得到；同一终端里的重复事件只更新 `last_seen`。
/// 观测数据（只能在事件发生时采到，不可由本地文件重推导）→ 升级不 DROP。
public final class SessionTerminalsRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    /// 落一次绑定（同键 upsert：首次插入记 first_seen，之后只推进 last_seen）。
    ///
    /// `origin` 用 MAX 合并 —— 字典序上 'probe' > 'hook'，所以这里显式取"更可信的那个"：
    /// 一旦被 hook 精确采过，后续探测结果不把它降级。
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
            // 主键列写空串而非 NULL —— NULL 进主键会让 upsert 永不命中
            .text(binding.bundleId ?? ""),
            .text(binding.tty ?? ""),
            binding.tmuxPane.map { .text($0) } ?? .null,
            .text(binding.origin.rawValue), .date(at), .date(at),
        ])
    }

    /// 某会话的全部绑定，最近活跃在前（详情页「曾在 N 个终端运行」用）
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

    /// 最近一次绑定（跳转目标）
    public func latest(source: AgentSource, sessionId: String) throws -> TerminalBinding? {
        try bindings(source: source, sessionId: sessionId).first?.binding
    }

    /// 批量取"每会话的最近一次绑定"，供列表页一次查完（避免每行一次查询）。
    /// 键为 `AgentTask.key(source:sessionId:)`，与 UI 侧的会话标识口径一致。
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
        sql += " ORDER BY last_seen ASC"  // 升序 → 后写的覆盖先写的，最终留下最新那条
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

    /// 主键列以空串代替 NULL 存盘，读出来要还原成 nil（否则 isEmpty / 展示逻辑会误判）
    private static func blankToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
