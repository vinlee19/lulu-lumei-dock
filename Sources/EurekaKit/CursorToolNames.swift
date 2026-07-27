import Foundation

/// Cursor 的工具词表（`bubbleId:*` 行的 `toolFormerData.name`，3.13.10 实勘全量）。
///
/// Cursor 的名字是 snake_case 且带 `_v2` 版本后缀（同一能力新旧两套并存），
/// 岛上与审计页要显示的是稳定可读的名字，所以统一在这里做一次归一化，
/// 顺便给 `AuditExtractor.cursor` 与用量分类提供同一份分类口径。
public enum CursorToolNames {
    /// MCP 工具前缀：Cursor 用 `mcp_<server>_<tool>`（单下划线，不是 Claude 的 `mcp__`）
    public static let mcpPrefix = "mcp_"

    /// 归一化后的展示名（`read_file_v2` → `read_file`；MCP 保留 `server.tool`）
    public static func displayName(_ raw: String) -> String {
        if isMCP(raw) { return mcpDisplayName(raw) }
        return canonical(raw)
    }

    /// 去掉 `_v2` / `_v3` 这类版本后缀，`rg` 归到 `ripgrep_raw_search`
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

    /// `mcp_dataworks-log-mcp_get_dag_instances_list` → `dataworks-log-mcp.get_dag_instances_list`。
    /// 服务名里可以有 `-` 但不会有 `_`（Cursor 用 `_` 当分隔符），所以按首个 `_` 切一刀。
    public static func mcpDisplayName(_ raw: String) -> String {
        let body = String(raw.dropFirst(mcpPrefix.count))
        guard let split = body.firstIndex(of: "_") else { return body }
        let server = String(body[body.startIndex..<split])
        let tool = String(body[body.index(after: split)...])
        return tool.isEmpty ? server : "\(server).\(tool)"
    }

    /// 用量页的工具分类（沿用 CodeBuddy/Kimi 的 skill / mcp / agent / tool 四类）。
    /// Cursor 没有 Skill 与子代理工具——子会话是 composer 而不是一次工具调用，
    /// 所以这里只会产出 mcp 与 tool 两类。
    public static func usageKind(_ raw: String) -> String {
        isMCP(raw) ? "mcp" : "tool"
    }
}
