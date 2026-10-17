import Foundation
import EurekaKit

/// tool_use / function_call → operation classification plus **full-fidelity** argument extraction
/// (no truncation).
/// This is the parsing core: the audit log needs complete commands/paths, and the session trail
/// (ToolStepExtractor) does its UI trimming on top of this.
public enum AuditExtractor {
    /// Classification of one operation: kind + display name + full arguments (whole command / file
    /// path / URL / pattern, no output body).
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

    // MARK: - Claude (tool_use blocks in assistant content)

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

    /// `mcp__server__tool` → `server.tool` (drops the claude_ai_ prefix; same rule as
    /// ClaudeTranscriptScanner.extractToolCalls)
    static func cleanMCPName(_ name: String) -> String {
        let comps = name.components(separatedBy: "__").filter { !$0.isEmpty }
        var server = comps.count >= 2 ? comps[1] : name
        if server.hasPrefix("claude_ai_") {
            server = String(server.dropFirst("claude_ai_".count))
        }
        let tool = comps.count >= 3 ? comps[2...].joined(separator: "__") : ""
        return tool.isEmpty ? server : "\(server).\(tool)"
    }

    // MARK: - Codex (response_item function_call; arguments is a JSON string)

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
            // command is an array (["bash","-lc","…"]); strip the bash -lc head
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
            return Operation(kind: .other, name: name, detail: L10n.text("Update plan", zhHans: "更新计划"))
        default:
            return Operation(kind: .other, name: name, detail: trim(firstString(in: args)))
        }
    }

    // MARK: - Codex custom tool channel (response_item custom_tool_call)

    /// **The main command/patch channel in current Codex**; only a few tools still go through
    /// `function_call`.
    /// Surveyed the 12 largest rollouts: `name` is only ever `exec`(1334) or `apply_patch`(97),
    /// and `input` is **not JSON**:
    ///  - `apply_patch` → `input` is the patch body itself (starts with `*** Begin Patch`)
    ///  - `exec` → `input` is a chunk of **JS source**; 7 shapes observed:
    ///    `await tools.exec_command({cmd: "…"})`(663) / `const patch = "*** Begin Patch…"`(110) /
    ///    bare patch body(97) / `tools.mcp__*`(72) / `tools.view_image`(71) /
    ///    `// @exec: {...}` comment header(45) / `tools.web__run`(35) / `tools.update_plan`(33)
    ///
    /// Classification matches `codex(name:argumentsJSON:)`, so the same operation gets the same
    /// kind/name in the audit log and the session trail whichever channel it took.
    public static func codexCustomTool(name: String, input: String?) -> Operation {
        let source = trim(input)
        // Patch: an explicit apply_patch, or exec carrying a bare patch / patch variable
        if name == "apply_patch" || source.hasPrefix("*** Begin Patch") {
            return Operation(kind: .edit, name: "apply_patch", detail: patchFilePaths(source))
        }
        if let patch = jsStringArgument(source, key: "patch"),
            patch.hasPrefix("*** Begin Patch") {
            return Operation(kind: .edit, name: "apply_patch", detail: patchFilePaths(patch))
        }
        // `tools.<name>(` → hand the inner tool name back to the codex vocabulary (same rule as the
        // function_call channel)
        if let inner = jsToolName(source) {
            if let cmd = jsStringArgument(source, key: "cmd") {
                return Operation(kind: .command, name: inner, detail: cmd)
            }
            if let command = jsStringArgument(source, key: "command") {
                return Operation(kind: .command, name: inner, detail: command)
            }
            if inner.hasPrefix("mcp__") {
                return Operation(
                    kind: .mcp, name: cleanMCPName(inner),
                    detail: jsFirstStringArgument(source))
            }
            switch inner {
            case "view_image":
                return Operation(
                    kind: .read, name: inner,
                    detail: jsStringArgument(source, key: "path") ?? "")
            case "update_plan":
                return Operation(kind: .other, name: inner, detail: L10n.text("Update plan", zhHans: "更新计划"))
            default:
                let isWeb = inner.hasPrefix("web") || inner.contains("search")
                return Operation(
                    kind: isWeb ? .web : .other, name: inner,
                    detail: jsFirstStringArgument(source))
            }
        }
        // Unrecognized shape: treat as a command and keep the whole thing (ToolStepExtractor only
        // takes the first line)
        return Operation(kind: .command, name: name, detail: source)
    }

    /// `custom_tool_call_output.output` / `function_call_output.output` → plain text.
    /// Two shapes observed: a string (2498 rows) and `[{type:"input_text", text:"…"}]` (126 rows).
    public static func codexOutputText(_ output: Any?) -> String {
        if let text = output as? String { return text }
        if let blocks = output as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    /// Tool result → success/failure. Returns nil when undecidable (callers then skip the backfill,
    /// leaving it "unknown" rather than pretending it succeeded).
    ///
    /// Both generations of the format must be recognized, because **files of both are still on disk**:
    ///  1. Old rollouts: `output` is a JSON string carrying `metadata.exit_code` (structured, most
    ///     accurate);
    ///  2. Current Codex: **that field is gone** (`metadata` appears 0 times across 2624 surveyed
    ///     `function_call_output` rows) → can only infer from output text: `Script failed`
    ///     (26 observed) / `Exit code: <N>`.
    public static func codexOutcome(_ output: Any?) -> (isError: Bool, exitCode: Int?)? {
        // Old format first: a structured exit code wins when present
        if let json = output as? String,
            let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
                as? [String: Any],
            let metadata = parsed["metadata"] as? [String: Any],
            let exitCode = metadata["exit_code"] as? Int {
            return (exitCode != 0, exitCode)
        }
        let text = codexOutputText(output)
        for line in text.split(separator: "\n") where line.hasPrefix("Exit code: ") {
            guard let code = Int(
                line.dropFirst("Exit code: ".count).trimmingCharacters(in: .whitespaces))
            else { continue }
            return (code != 0, code)
        }
        if text.hasPrefix("Script failed") { return (true, nil) }
        if text.hasPrefix("Script completed") { return (false, nil) }
        return nil
    }

    // MARK: - Literal extraction from JS source (Codex custom_tool_call only)

    /// `await tools.<name>(` → `<name>`; nil if not found.
    /// Only the `tools.` prefix is recognized (every observed shape has it), so words in comments
    /// aren't mistaken for tool names.
    static func jsToolName(_ source: String) -> String? {
        guard let range = source.range(of: "tools.") else { return nil }
        let name = source[range.upperBound...].prefix {
            $0.isLetter || $0.isNumber || $0 == "_"
        }
        return name.isEmpty ? nil : String(name)
    }

    /// Reads the string value of JS `<key>: "…"` (object property) or `<key> = "…"` (variable
    /// assignment) and unescapes it. Both separators are needed: observed `cmd:` uses a property,
    /// `const patch = "*** Begin Patch…"` uses an assignment. Hand-written scan instead of a regex:
    /// values contain `"` `\n` `'` etc. which are hard to get right in a regex; it also avoids
    /// splicing external input into a regex.
    static func jsStringArgument(_ source: String, key: String) -> String? {
        let chars = Array(source)
        let name = Array(key)
        var index = 0
        while index + name.count < chars.count {
            defer { index += 1 }
            guard Array(chars[index..<(index + name.count)]) == name else { continue }
            // The previous character must be a separator, otherwise `foo_cmd:` would match `cmd:`
            if index > 0 {
                let prev = chars[index - 1]
                if prev.isLetter || prev.isNumber || prev == "_" { continue }
            }
            var cursor = index + name.count
            func skipSpace() {
                while cursor < chars.count,
                    chars[cursor] == " " || chars[cursor] == "\n" || chars[cursor] == "\t" {
                    cursor += 1
                }
            }
            skipSpace()
            guard cursor < chars.count, chars[cursor] == ":" || chars[cursor] == "=" else {
                continue
            }
            cursor += 1
            skipSpace()
            guard cursor < chars.count, chars[cursor] == "\"" || chars[cursor] == "'" else {
                continue
            }
            return unescapeJS(chars, from: cursor)
        }
        return nil
    }

    /// Fallback summary: the first string literal in the whole source (for MCP/unknown tools)
    static func jsFirstStringArgument(_ source: String) -> String {
        let chars = Array(source)
        for (index, char) in chars.enumerated() where char == "\"" {
            if let value = unescapeJS(chars, from: index), !value.isEmpty { return value }
        }
        return ""
    }

    /// Reads a JS string literal starting at the quote at `chars[start]` and unescapes it (nil if
    /// unterminated)
    private static func unescapeJS(_ chars: [Character], from start: Int) -> String? {
        let quote = chars[start]
        var result = ""
        var index = start + 1
        while index < chars.count {
            let char = chars[index]
            if char == "\\", index + 1 < chars.count {
                switch chars[index + 1] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "'": result.append("'")
                case let other: result.append(other)
                }
                index += 2
                continue
            }
            if char == quote { return result }
            result.append(char)
            index += 1
        }
        return nil  // unterminated (truncated upstream) → caller takes the fallback
    }

    // MARK: - Cursor / Grok (snake_case tool vocabulary, nearly identical between the two)

    /// Grok's `chat_history.jsonl` has `assistant.tool_calls[] = {id, name, arguments}`, with
    /// `arguments` a JSON string. The vocabulary overlaps heavily with Cursor (observed
    /// `read_file`(target_file) / `grep`(pattern,path) / `run_terminal_command`(command) /
    /// `search_replace`(file_path) / `list_dir`(target_directory) / `write`(file_path) /
    /// `todo_write` all share names and params), so `cursor(name:input:)` is reused directly, with
    /// only Grok's few unique tools added there.
    public static func grok(name: String, argumentsJSON: String?) -> Operation {
        cursor(name: name, input: cursorArguments(rawArgs: argumentsJSON, params: nil))
    }

    /// Qwen's `functionCall.args` is already a structured object (unlike Codex/Grok's JSON string),
    /// so it goes straight into the shared snake_case mapping. Observed `read_file`(**file_path**,
    /// not Cursor's `target_file`) / `grep_search` / `agent` / `ask_user_question`.
    public static func qwen(name: String, args: [String: Any]?) -> Operation {
        cursor(name: name, input: args)
    }

    /// Cursor tool names are snake_case with a `_v2` suffix (old and new sets coexist), so
    /// normalize before classifying; MCP is single-underscore `mcp_<server>_<tool>`, unlike
    /// Claude's `mcp__`, so `claude(name:input:)` can't be reused - everything would hit default
    /// and risk rules would never match.
    ///
    /// `input` is assembled by `cursorArguments(rawArgs:params:)`: `rawArgs` (JSON string) is primary,
    /// `params` (structured fields Cursor extracts itself) fills gaps. `apply_patch`'s rawArgs is
    /// bare patch text, not JSON (observed 62/3936 rows), so the path comes from
    /// `params.relativeWorkspacePath`.
    public static func cursor(name: String, input: [String: Any]?) -> Operation {
        // Claude-style `mcp__server__tool`: Grok uses this double-underscore form (observed
        // notion__*); recognize it first, otherwise it hits default as .other and the audit page
        // can't classify MCP calls
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
            return Operation(kind: .other, name: canonical, detail: L10n.text("Update plan", zhHans: "更新计划"))
        // The following appear only in Grok (not Cursor); classified the same way as similar tools
        case "web_fetch":
            return Operation(kind: .web, name: canonical, detail: trim(str("url")))
        case "search_tool":
            return Operation(kind: .search, name: canonical, detail: trim(str("query")))
        case "spawn_subagent":
            return Operation(
                kind: .agent, name: str("subagent_type") ?? canonical,
                detail: trim(str("description", "prompt")))
        case "use_tool":
            // Grok's MCP bridge: the real tool name is in tool_name (observed as Claude-style
            // `mcp__` or `<server>__<tool>`), arguments in tool_input - **usually an object, not a
            // string**; reading it as a string yields an empty detail (observed 40/40 empty) → also
            // look one level into the nested dictionary.
            let inner = input?["tool_input"] as? [String: Any]
            let rawName = str("tool_name") ?? canonical
            return Operation(
                kind: .mcp,
                name: rawName.contains("__") ? cleanMCPName(rawName) : rawName,
                detail: trim(str("tool_input") ?? firstString(in: inner)))
        case "exit_plan_mode":
            return Operation(kind: .other, name: canonical, detail: L10n.text("Exit plan mode", zhHans: "退出计划模式"))
        case "agent":
            return Operation(
                kind: .agent, name: str("subagent_type") ?? canonical,
                detail: trim(str("description", "prompt")))
        case "ask_user_question":
            return Operation(kind: .other, name: canonical, detail: L10n.text("Ask the user", zhHans: "向用户提问"))
        default:
            return Operation(kind: .other, name: canonical, detail: trim(firstString(in: input)))
        }
    }

    /// Where the raw text goes when `rawArgs` fails to parse (`apply_patch`'s bare patch text)
    public static let cursorRawArgsKey = "__rawArgs"

    /// Merges the two argument sources of `toolFormerData` into one dictionary: `rawArgs` is the
    /// raw model input, `params` the structured fields Cursor extracts (present on 3985/6505
    /// observed rows); the latter only fills keys the former lacks.
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

    /// Extracts file paths from an apply_patch body (`*** Update/Add/Delete File: <path>` lines)
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

    /// First String value (fallback summary for MCP/unknown tools; keys sorted for determinism)
    static func firstString(in input: [String: Any]?) -> String {
        guard let input else { return "" }
        for key in input.keys.sorted() {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }

    /// Trims surrounding whitespace only (no length truncation)
    private static func trim(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
