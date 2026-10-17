import Foundation
import EurekaKit

/// Scans the live subagent state of one ZCode session (pure function, for unit tests).
/// Lightweight snapshot: reads only `~/.zcode/cli/agents/<sess>/agent_*/metadata.json`,
/// no incremental tail (feeding subagent rollout/transcript lines into the island would
/// create phantom tasks).
///
/// On-disk layout (observed 2026-08, ~/.zcode/cli/agents):
/// - `<sess>/agent_<id>/metadata.json` = one subagent: `profileSnapshot.name` gives the type
///   (e.g. "Explore"), `description` the task description, `status` (running/completed/failed),
///   `createdAt/updatedAt/completedAt` ISO8601, `usage` the token totals (collected separately
///   by the scanner).
/// - current tool: the last tool_call_scheduled/toolName in the tail window of the subdir's
///   transcript.jsonl.
public enum ZcodeSubagentScanner {
    /// `sessionDir` = `agents/<sess_<uuid>>/` (the dir holding each agent_<id>/).
    /// `turnStartedAt` = start of the main session's current turn: subagents created before it
    /// are leftovers from an old turn and are filtered out.
    public static func scan(
        sessionDir: URL,
        turnStartedAt: Date? = nil,
        now: Date = Date(),
        tailBytes: Int = 32768
    ) -> [SubagentInfo] {
        let fm = FileManager.default
        let agentDirs = ((try? fm.contentsOfDirectory(
            at: sessionDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter {
                $0.lastPathComponent.hasPrefix("agent_")
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
        guard !agentDirs.isEmpty else { return [] }

        var infos: [SubagentInfo] = []
        for dir in agentDirs {
            let metaURL = dir.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let root = object as? [String: Any]
            else { continue }
            let createdAt = ZcodeRolloutDecoder.parseISO(root["createdAt"] as? String)
            // Keep only subagents spawned in this turn
            if let turnStartedAt, let createdAt, createdAt < turnStartedAt { continue }

            let status: SubagentInfo.Status
            switch root["status"] as? String {
            case "completed", "succeeded": status = .completed
            case "failed", "error", "cancelled": status = .failed
            case "running": status = .running
            default:
                // No status field: fall back to the completion time; without one, treat as
                // running
                status = (root["completedAt"] as? String).flatMap(ZcodeRolloutDecoder.parseISO) != nil
                    ? .completed : .running
            }

            let profile = root["profileSnapshot"] as? [String: Any]
            infos.append(SubagentInfo(
                agentId: dir.lastPathComponent,
                agentType: (profile?["name"] as? String) ?? "subagent",
                description: (root["description"] as? String) ?? "",
                status: status,
                currentActivity: status == .running
                    ? lastToolName(dir: dir, tailBytes: tailBytes) : nil,
                startedAt: createdAt,
                finishedAt: nil))  // keeps snapshots dedupable: finishedAt always nil (same as the kimi/claude scanners)
        }

        // Stable sort: earlier start time first; without a time, fall back to agentId
        return infos.sorted {
            switch ($0.startedAt, $1.startedAt) {
            case let (l?, r?) where l != r: return l < r
            default: return $0.agentId < $1.agentId
            }
        }
    }

    /// Last tool name in the tail window of a subagent's transcript.jsonl
    /// (tool_call_scheduled.toolName)
    private static func lastToolName(dir: URL, tailBytes: Int) -> String? {
        let transcript = dir.appendingPathComponent("transcript.jsonl")
        guard
            let handle = FileHandle(forReadingAtPath: transcript.path),
            let size = try? handle.seekToEnd(), size > 0
        else { return nil }
        defer { try? handle.close() }
        let length = min(size, UInt64(tailBytes))
        guard (try? handle.seek(toOffset: size - length)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }
        var last: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let root = object as? [String: Any],
                root["type"] as? String == "tool_call_scheduled",
                let payload = root["payload"] as? [String: Any],
                let name = payload["toolName"] as? String, !name.isEmpty
            else { continue }
            last = name
        }
        return last
    }
}
