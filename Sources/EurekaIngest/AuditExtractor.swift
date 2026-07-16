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
