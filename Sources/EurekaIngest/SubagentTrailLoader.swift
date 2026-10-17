import EurekaKit
import Foundation

/// Loads subagent-internal trails: `<sessionId>/subagents/agent-<id>.{meta.json,jsonl}` → placed
/// by `toolUseId`.
///
/// **The parent-child edge is exact on disk** (the meta's `toolUseId` is the id of that `tool_use`
/// in the parent transcript), so no time-window heuristic is needed. `ClaudeSubagentScanner` reads
/// this field but only uses it to decide completion and drops it when building `SubagentInfo`;
/// this puts it to use.
///
/// A subagent jsonl uses **the same Claude envelope** as the main transcript, but every line has
/// `isSidechain == true` (all 116 lines in a local sample), so it can't be fed straight to
/// `TranscriptReader.loadClaude`, whose `guard isSidechain != true` would drop every assistant
/// line. This does its own minimal parse: tool_use only, no body text (body text is useless to
/// the lineage graph and would blow up memory).
public enum SubagentTrailLoader {
    /// Max steps collected per subagent. Subagents routinely run dozens of steps; taking all of
    /// them would drown the parent graph. The overflow shows in the UI as "… N more steps".
    public static let maxStepsPerAgent = 40

    /// Main transcript path → `toolUseId: [ToolStep]`
    public static func load(mainTranscriptPath: String) -> [String: [ToolStep]] {
        let base = URL(fileURLWithPath: mainTranscriptPath)
            .deletingPathExtension()
            .appendingPathComponent("subagents", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil)
        else { return [:] }

        var result: [String: [ToolStep]] = [:]
        for meta in entries.filter({ $0.lastPathComponent.hasSuffix(".meta.json") }) {
            guard let data = try? Data(contentsOf: meta),
                let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let toolUseId = info["toolUseId"] as? String, !toolUseId.isEmpty
            else { continue }
            // agent-<id>.meta.json → agent-<id>.jsonl
            let name = meta.lastPathComponent.replacingOccurrences(
                of: ".meta.json", with: ".jsonl")
            let transcript = base.appendingPathComponent(name)
            let steps = steps(at: transcript)
            if !steps.isEmpty { result[toolUseId] = steps }
        }
        return result
    }

    /// Subagent transcript → tool steps (tool_use only, with tool_result failure flags
    /// back-filled)
    static func steps(at url: URL) -> [ToolStep] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        var steps: [ToolStep] = []
        var indexByCallId: [String: Int] = [:]
        var batch = 0

        for lineData in data.split(separator: UInt8(ascii: "\n")) {
            guard let root = (try? JSONSerialization.jsonObject(with: Data(lineData)))
                as? [String: Any],
                let message = root["message"] as? [String: Any],
                let blocks = message["content"] as? [[String: Any]]
            else { continue }
            switch root["type"] as? String {
            case "assistant":
                batch += 1
                for block in blocks where block["type"] as? String == "tool_use" {
                    guard steps.count < maxStepsPerAgent else { break }
                    var step = ToolStepExtractor.claude(
                        name: block["name"] as? String ?? L10n.text("Tool", zhHans: "工具"),
                        input: block["input"] as? [String: Any])
                    step.batch = batch
                    step.callId = block["id"] as? String
                    steps.append(step)
                    if let callId = step.callId { indexByCallId[callId] = steps.count - 1 }
                }
            case "user":
                for block in blocks where block["type"] as? String == "tool_result" {
                    guard block["is_error"] as? Bool == true,
                        let callId = block["tool_use_id"] as? String,
                        let index = indexByCallId[callId]
                    else { continue }
                    steps[index].isError = true
                }
            default:
                break
            }
        }
        return steps
    }
}
