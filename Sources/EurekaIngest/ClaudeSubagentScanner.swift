import Foundation
import EurekaKit

/// Scans the live subagent state of one Claude session (pure function, easy to unit test). Qoder
/// reuses this scanner (`~/.qoder-cn/projects/<slug>/<sessionId>/` has the same layout as Claude,
/// verified on v1.1.5).
///
/// On-disk conventions (verified against the current Claude Code release):
/// - `<sessionDir>/subagents/agent-<id>.meta.json` = `{agentType, description, toolUseId}`, created
///   as soon as the subagent is spawned. Qoder names the meta file `agent-<type>-<hex>.meta.json`;
///   the same derivation yields the id `<type>-<hex>`.
/// - `<sessionDir>/subagents/agent-<id>.jsonl` = the subagent transcript; the name of the last
///   tool_use in its tail = the current tool.
/// - Completion signal: a `tool_result` appears in the parent transcript
///   (`tool_use_id == toolUseId`); `is_error` → failed. Large results get offloaded to
///   `<sessionDir>/tool-results/<toolUseId>.txt` (fallback completion criterion). Qoder also has
///   `subagents/task-<id>.json` recording the terminal state (`status`/"completed" etc.), used as a
///   second fallback.
public enum ClaudeSubagentScanner {
    /// `sessionDir` = `<project>/<sessionId>/` (the directory next to `<sessionId>.jsonl`).
    /// `parentTranscript` = `<sessionId>.jsonl` (its tail window is read for tool_result).
    /// `turnStartedAt` = start of the current turn (prompt time): the subagents/ directory
    /// accumulates across turns, so only subagents created in this turn are kept (meta creation
    /// time ≥ it); nil disables the filter.
    public static func scan(
        sessionDir: URL,
        parentTranscript: URL?,
        turnStartedAt: Date? = nil,
        tailBytes: Int = 262144
    ) -> [SubagentInfo] {
        let fm = FileManager.default
        let subagentsDir = sessionDir.appendingPathComponent("subagents", isDirectory: true)
        let metas = (try? fm.contentsOfDirectory(
            at: subagentsDir, includingPropertiesForKeys: [.creationDateKey]))?
            .filter { $0.lastPathComponent.hasSuffix(".meta.json") } ?? []
        guard !metas.isEmpty else { return [] }  // Codex / no subagents

        // tool_result entries in the parent transcript's tail window: tool_use_id → is_error
        let completion = parentTranscript.map { toolResults(in: $0, tailBytes: tailBytes) } ?? [:]
        let resultsDir = sessionDir.appendingPathComponent("tool-results", isDirectory: true)

        var infos: [SubagentInfo] = []
        for meta in metas {
            let createdAt = (try? meta.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            // Keep only subagents spawned in this turn (meta created after the prompt)
            if let turnStartedAt, let createdAt, createdAt < turnStartedAt { continue }
            guard
                let data = try? Data(contentsOf: meta),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let toolUseId = obj["toolUseId"] as? String
            else { continue }
            let agentId = meta.lastPathComponent
                .replacingOccurrences(of: "agent-", with: "")
                .replacingOccurrences(of: ".meta.json", with: "")
            let agentType = obj["agentType"] as? String ?? "agent"
            let description = obj["description"] as? String ?? ""

            let status: SubagentInfo.Status
            if let isError = completion[toolUseId] {
                status = isError ? .failed : .completed
            } else if fm.fileExists(
                atPath: resultsDir.appendingPathComponent("\(toolUseId).txt").path) {
                status = .completed  // inline result left the tail window; the offloaded file remains
            } else if let taskStatus = taskFileStatus(agentId: agentId, in: subagentsDir) {
                status = taskStatus  // Qoder fallback: the terminal-state record in task-<id>.json
            } else {
                status = .running
            }

            // Read the transcript tail for the current tool only for running subagents (saves IO)
            var currentActivity: String?
            if status == .running {
                let jsonl = subagentsDir.appendingPathComponent("agent-\(agentId).jsonl")
                currentActivity = lastToolUse(in: jsonl, tailBytes: 32768)
            }

            infos.append(SubagentInfo(
                agentId: agentId,
                agentType: agentType,
                description: description,
                status: status,
                currentActivity: currentActivity,
                startedAt: createdAt,
                finishedAt: nil))  // UI doesn't show it; nil keeps scan results dedupable
        }

        // Stable sort: earlier start time first; entries without a time fall back to agentId
        return infos.sorted {
            switch ($0.startedAt, $1.startedAt) {
            case let (l?, r?) where l != r: return l < r
            default: return $0.agentId < $1.agentId
            }
        }
    }

    // MARK: - Parsing

    /// tool_use_id → is_error for every finished subagent in the parent transcript's tail window.
    /// A background agent's tool_result only acknowledges the launch (`async_launched`); it
    /// finishes with the `<task-notification>` naming its tool_use_id (status other than
    /// "completed" → failed).
    private static func toolResults(in url: URL, tailBytes: Int) -> [String: Bool] {
        guard let data = tail(of: url, bytes: tailBytes) else { return [:] }
        var map: [String: Bool] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let type = root["type"] as? String
            else { continue }
            for report in ClaudeBackgroundTasks.reports(root, type: type) {
                if let toolUseId = report.toolUseId { map[toolUseId] = report.status != "completed" }
            }
            guard
                type == "user",
                ClaudeBackgroundTasks.launchedId(root, type: type) == nil,
                let message = root["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { continue }
            for block in content where block["type"] as? String == "tool_result" {
                if let tid = block["tool_use_id"] as? String {
                    map[tid] = (block["is_error"] as? Bool) ?? false
                }
            }
        }
        return map
    }

    /// Terminal state from Qoder's `subagents/task-<agentId>.json` ("completed"/"failed" etc.); nil
    /// if the file doesn't exist or is still running ("running" etc.)
    private static func taskFileStatus(agentId: String, in subagentsDir: URL) -> SubagentInfo.Status? {
        let url = subagentsDir.appendingPathComponent("task-\(agentId).json")
        guard
            let data = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let status = obj["status"] as? String
        else { return nil }
        switch status {
        case "completed": return .completed
        case "failed", "error": return .failed
        default: return nil
        }
    }

    /// Tool name of the last assistant tool_use in the subagent transcript's tail window
    private static func lastToolUse(in url: URL, tailBytes: Int) -> String? {
        guard let data = tail(of: url, bytes: tailBytes) else { return nil }
        var last: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                root["type"] as? String == "assistant",
                let message = root["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { continue }
            for block in content where block["type"] as? String == "tool_use" {
                if let name = block["name"] as? String { last = name }
            }
        }
        return last
    }

    /// Reads the trailing bytes of a file (the whole file if shorter), the same tail-window read as
    /// ClaudeSessionBootstrap
    private static func tail(of url: URL, bytes: Int) -> Data? {
        guard
            let handle = FileHandle(forReadingAtPath: url.path),
            let size = try? handle.seekToEnd(), size > 0
        else { return nil }
        defer { try? handle.close() }
        let length = min(size, UInt64(bytes))
        guard (try? handle.seek(toOffset: size - length)) != nil else { return nil }
        return try? handle.readToEnd()
    }
}
