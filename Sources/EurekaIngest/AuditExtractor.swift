import Foundation
import EurekaKit

/// tool_use / function_call → 操作分类与参数**全保真**提取（不截断）。
/// 这是解析核心：审计日志要完整命令/路径，会话轨迹（ToolStepExtractor）在此之上做 UI 裁剪。
public enum AuditExtractor {
    /// 一次操作的分类结果：kind + 展示名 + 完整参数（命令全文/文件路径/URL/pattern，无输出正文）。
    public struct Operation: Equatable, Sendable {
        public var kind: ToolKind
        public var name: String
        public var detail: String

        public init(kind: ToolKind, name: String, detail: String) {
            self.kind = kind
            self.name = name
            self.detail = detail
        }
    }

    // MARK: - Claude（assistant content 的 tool_use 块）

    public static func claude(name: String, input: [String: Any]?) -> Operation {
        switch name {
        case "Read":
            return Operation(kind: .read, name: name, detail: trim(input?["file_path"] as? String))
        case "Glob":
            return Operation(kind: .search, name: name, detail: trim(input?["pattern"] as? String))
        case "Grep":
            var detail = (input?["pattern"] as? String) ?? ""
            if let path = input?["path"] as? String, !path.isEmpty {
                detail += " in \(path)"
            }
            return Operation(kind: .search, name: name, detail: trim(detail))
        case "WebSearch":
            return Operation(kind: .web, name: name, detail: trim(input?["query"] as? String))
        case "WebFetch":
            return Operation(kind: .web, name: name, detail: trim(input?["url"] as? String))
        case "Bash", "BashOutput", "KillShell":
            return Operation(kind: .command, name: name, detail: trim(input?["command"] as? String))
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return Operation(kind: .edit, name: name, detail: trim(input?["file_path"] as? String))
        case "Task", "Agent":
            let subagent = (input?["subagent_type"] as? String) ?? name
            return Operation(kind: .agent, name: subagent, detail: trim(input?["description"] as? String))
        case "Skill":
            return Operation(
                kind: .skill, name: (input?["skill"] as? String) ?? name,
                detail: trim(input?["args"] as? String))
        default:
            if name.hasPrefix("mcp__") {
                return Operation(kind: .mcp, name: cleanMCPName(name), detail: trim(firstString(in: input)))
            }
            return Operation(kind: .other, name: name, detail: "")
        }
    }

    /// `mcp__server__tool` → `server.tool`（去 claude_ai_ 前缀；口径同 ClaudeTranscriptScanner.extractToolCalls）
    static func cleanMCPName(_ name: String) -> String {
        let comps = name.components(separatedBy: "__").filter { !$0.isEmpty }
        var server = comps.count >= 2 ? comps[1] : name
        if server.hasPrefix("claude_ai_") {
            server = String(server.dropFirst("claude_ai_".count))
        }
        let tool = comps.count >= 3 ? comps[2...].joined(separator: "__") : ""
        return tool.isEmpty ? server : "\(server).\(tool)"
    }

    // MARK: - Codex（response_item 的 function_call，arguments 是 JSON 字符串）

    public static func codex(name: String, argumentsJSON: String?) -> Operation {
        let args = argumentsJSON.flatMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        switch name {
        case "exec_command":
            return Operation(kind: .command, name: name, detail: trim(args?["cmd"] as? String))
        case "shell_command":
            return Operation(kind: .command, name: name, detail: trim(args?["command"] as? String))
        case "shell":
            // command 是数组形态（["bash","-lc","…"]），去 bash -lc 头
            var parts = (args?["command"] as? [Any])?.compactMap { $0 as? String } ?? []
            if parts.count >= 3, parts[0].hasSuffix("bash"), parts[1] == "-lc" {
                parts.removeFirst(2)
            }
            return Operation(kind: .command, name: name, detail: trim(parts.joined(separator: " ")))
        case "write_stdin":
            return Operation(kind: .command, name: name, detail: trim(args?["chars"] as? String))
        case "apply_patch":
            return Operation(kind: .edit, name: name, detail: trim(patchFilePaths(args?["input"] as? String)))
        case "view_image":
            return Operation(kind: .read, name: name, detail: trim(args?["path"] as? String))
        case "update_plan":
            return Operation(kind: .other, name: name, detail: "更新计划")
        default:
            return Operation(kind: .other, name: name, detail: trim(firstString(in: args)))
        }
    }

    // MARK: - Cursor / Grok（snake_case 工具词表，两家几乎一致）

    /// Grok 的 `chat_history.jsonl` 里 `assistant.tool_calls[] = {id, name, arguments}`，
    /// `arguments` 是 JSON 字符串。词表与 Cursor 高度重合（实勘 `read_file`(target_file) /
    /// `grep`(pattern,path) / `run_terminal_command`(command) / `search_replace`(file_path) /
    /// `list_dir`(target_directory) / `write`(file_path) / `todo_write` 全同名同参），
    /// 故直接复用 `cursor(name:input:)`，只在那里补 Grok 独有的几个。
    public static func grok(name: String, argumentsJSON: String?) -> Operation {
        cursor(name: name, input: cursorArguments(rawArgs: argumentsJSON, params: nil))
    }

    /// Qwen 的 `functionCall.args` 已是结构化对象（不像 Codex/Grok 是 JSON 字符串），
    /// 直接进共享的 snake_case 映射。实勘 `read_file`(**file_path**，不是 Cursor 的
    /// `target_file`) / `grep_search` / `agent` / `ask_user_question`。
    public static func qwen(name: String, args: [String: Any]?) -> Operation {
        cursor(name: name, input: args)
    }

    /// Cursor 的工具名是 snake_case 且带 `_v2` 后缀（新旧两套并存），先归一化再分类；
    /// MCP 是单下划线的 `mcp_<server>_<tool>`，与 Claude 的 `mcp__` 不同，
    /// 所以不能复用 `claude(name:input:)`——那样会全部落 default，风险规则永不命中。
    ///
    /// `input` 由 `cursorArguments(rawArgs:params:)` 拼出：`rawArgs`（JSON 字符串）为主，
    /// `params`（Cursor 自己摘出来的结构化字段）补缺。`apply_patch` 的 rawArgs 是
    /// 裸补丁文本不是 JSON（实勘 62/3936 行），走 `params.relativeWorkspacePath` 取路径。
    public static func cursor(name: String, input: [String: Any]?) -> Operation {
        // Claude 式 `mcp__server__tool`：Grok 用的是这种双下划线写法（实勘 notion__*），
        // 先认它，否则会落 default 归成 .other，MCP 调用在审计页就分不出类
        if name.hasPrefix("mcp__") {
            return Operation(
                kind: .mcp, name: cleanMCPName(name), detail: trim(firstString(in: input)))
        }
        if CursorToolNames.isMCP(name) {
            return Operation(
                kind: .mcp, name: CursorToolNames.mcpDisplayName(name),
                detail: trim(firstString(in: input)))
        }
        let canonical = CursorToolNames.canonical(name)
        func str(_ keys: String...) -> String? {
            for key in keys {
                if let value = input?[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        func list(_ key: String) -> [String] {
            (input?[key] as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
        }
        switch canonical {
        case "read_file":
            return Operation(
                kind: .read, name: canonical,
                detail: trim(str("target_file", "file_path", "path")))
        case "read_lints":
            return Operation(
                kind: .read, name: canonical, detail: list("paths").joined(separator: ", "))
        case "list_dir":
            return Operation(
                kind: .search, name: canonical, detail: trim(str("target_directory", "path")))
        case "glob_file_search":
            return Operation(kind: .search, name: canonical, detail: trim(str("glob_pattern")))
        case "grep", "grep_search", "ripgrep_raw_search":
            var detail = str("pattern", "query") ?? ""
            let scope = str("path") ?? list("target_directories").joined(separator: ", ")
            if !scope.isEmpty { detail += " in \(scope)" }
            return Operation(kind: .search, name: canonical, detail: trim(detail))
        case "codebase_search":
            return Operation(kind: .search, name: canonical, detail: trim(str("query")))
        case "web_search":
            return Operation(kind: .web, name: canonical, detail: trim(str("search_term", "query")))
        case "run_terminal_cmd", "run_terminal_command":
            return Operation(kind: .command, name: canonical, detail: trim(str("command")))
        case "search_replace", "write", "edit_file", "delete_file":
            return Operation(
                kind: .edit, name: canonical,
                detail: trim(str("file_path", "target_file", "relativeWorkspacePath")))
        case "apply_patch":
            let path = str("relativeWorkspacePath", "target_file")
                ?? patchFilePaths(str("patch", "input", cursorRawArgsKey))
            return Operation(kind: .edit, name: canonical, detail: trim(path))
        case "todo_write":
            return Operation(kind: .other, name: canonical, detail: "更新计划")
        // 以下几个只在 Grok 出现（Cursor 没有），归类口径与同类工具保持一致
        case "web_fetch":
            return Operation(kind: .web, name: canonical, detail: trim(str("url")))
        case "search_tool":
            return Operation(kind: .search, name: canonical, detail: trim(str("query")))
        case "spawn_subagent":
            return Operation(
                kind: .agent, name: str("subagent_type") ?? canonical,
                detail: trim(str("description", "prompt")))
        case "use_tool":
            // Grok 的 MCP 桥：真正的工具名在 tool_name 里（实勘是 Claude 式 `mcp__` 或
            // `<server>__<tool>`），入参在 tool_input —— **它通常是对象而不是字符串**，
            // 直接当字符串取会得到空 detail（实勘 40/40 条全空）→ 嵌套字典也要往里取一层。
            let inner = input?["tool_input"] as? [String: Any]
            let rawName = str("tool_name") ?? canonical
            return Operation(
                kind: .mcp,
                name: rawName.contains("__") ? cleanMCPName(rawName) : rawName,
                detail: trim(str("tool_input") ?? firstString(in: inner)))
        case "exit_plan_mode":
            return Operation(kind: .other, name: canonical, detail: "退出计划模式")
        case "agent":
            return Operation(
                kind: .agent, name: str("subagent_type") ?? canonical,
                detail: trim(str("description", "prompt")))
        case "ask_user_question":
            return Operation(kind: .other, name: canonical, detail: "向用户提问")
        default:
            return Operation(kind: .other, name: canonical, detail: trim(firstString(in: input)))
        }
    }

    /// `rawArgs` 解析失败时把原文塞进这个 key（`apply_patch` 的裸补丁文本）
    public static let cursorRawArgsKey = "__rawArgs"

    /// `toolFormerData` 的两个参数源合并成一个字典：`rawArgs` 是模型给的原始入参，
    /// `params` 是 Cursor 摘出来的结构化字段（实勘 3985/6505 条有），后者只补前者没有的 key。
    public static func cursorArguments(rawArgs: Any?, params: Any?) -> [String: Any] {
        var merged: [String: Any] = [:]
        if let raw = rawArgs as? String, !raw.isEmpty {
            if let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)))
                as? [String: Any] {
                merged = parsed
            } else {
                merged[cursorRawArgsKey] = raw
            }
        } else if let dict = rawArgs as? [String: Any] {
            merged = dict
        }
        for (key, value) in (params as? [String: Any] ?? [:]) where merged[key] == nil {
            merged[key] = value
        }
        return merged
    }

    /// apply_patch 正文提取文件路径（`*** Update/Add/Delete File: <path>` 行）
    static func patchFilePaths(_ patch: String?) -> String {
        guard let patch else { return "" }
        var paths: [String] = []
        for line in patch.split(separator: "\n") {
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
            where line.hasPrefix(marker) {
                paths.append(String(line.dropFirst(marker.count)))
            }
        }
        return paths.joined(separator: ", ")
    }

    /// 首个 String 值（MCP/未知工具的兜底摘要；按 key 排序保证确定性）
    static func firstString(in input: [String: Any]?) -> String {
        guard let input else { return "" }
        for key in input.keys.sorted() {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }

    /// 仅去首尾空白（不截断长度）
    private static func trim(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
