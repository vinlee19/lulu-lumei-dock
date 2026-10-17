import Foundation

/// Cursor's tool vocabulary (`toolFormerData.name` on `bubbleId:*` rows; full set inspected on
/// 3.13.10).
///
/// Cursor's names are snake_case with a `_v2` version suffix (old and new sets of the same
/// capability coexist), while the island and audit page need stable readable names, so they
/// are normalized once here -- which also gives `AuditExtractor.cursor` and usage
/// classification one shared classification rule.
public enum CursorToolNames {
    /// MCP tool prefix: Cursor uses `mcp_<server>_<tool>` (single underscore, not Claude's
    /// `mcp__`)
    public static let mcpPrefix = "mcp_"

    /// Normalized display name (`read_file_v2` → `read_file`; MCP keeps `server.tool`)
    public static func displayName(_ raw: String) -> String {
        if isMCP(raw) { return mcpDisplayName(raw) }
        return canonical(raw)
    }

    /// Strips version suffixes like `_v2` / `_v3`; `rg` maps to `ripgrep_raw_search`
    public static func canonical(_ raw: String) -> String {
        if raw == "rg" { return "ripgrep_raw_search" }
        guard let range = raw.range(of: "_v[0-9]+$", options: .regularExpression) else {
            return raw
        }
        return String(raw[raw.startIndex..<range.lowerBound])
    }

    public static func isMCP(_ raw: String) -> Bool {
        raw.hasPrefix(mcpPrefix) && raw.count > mcpPrefix.count
    }

    /// `mcp_dataworks-log-mcp_get_dag_instances_list` → `dataworks-log-mcp.get_dag_instances_list`.
    /// Server names may contain `-` but never `_` (Cursor uses `_` as the separator), so split
    /// once at the first `_`.
    public static func mcpDisplayName(_ raw: String) -> String {
        let body = String(raw.dropFirst(mcpPrefix.count))
        guard let split = body.firstIndex(of: "_") else { return body }
        let server = String(body[body.startIndex..<split])
        let tool = String(body[body.index(after: split)...])
        return tool.isEmpty ? server : "\(server).\(tool)"
    }

    /// Tool classification for the usage page (reuses CodeBuddy/Kimi's four kinds: skill /
    /// mcp / agent / tool). Cursor has no Skill or subagent tools -- a child session is a
    /// composer, not a tool call -- so only mcp and tool are produced here.
    public static func usageKind(_ raw: String) -> String {
        isMCP(raw) ? "mcp" : "tool"
    }
}
