import Foundation
import EurekaKit

/// Scans the live subagent state of one CodeBuddy session (pure function, easy to unit test).
///
/// On-disk layout (observed 2026-07, ~/.codebuddy): CodeBuddy has no Claude-style meta.json; all
/// spawn info lives in the parent transcript `<sessionId>.jsonl`:
/// - `function_call` lines with name ∈ {TaskCreate, Agent, AgentSwarm}: `callId` + `arguments` (a
///   JSON string: Agent carries description/prompt/subagent_type, TaskCreate carries
///   subject/description).
/// - The paired `function_call_result` line (same callId): `status:"completed"` → completed,
///   anything else → failed.
/// - Subagent transcripts are `subagents/agent-<hex>.jsonl`, with no mapping from filename to
///   callId; a running agent's current tool is found by prefix-matching its prompt against each
///   subfile's first user message (observed to match one-to-one) and taking the last function_call
///   name in its tail window. agent id = callId.
public enum CodeBuddySubagentScanner {
    /// `sessionDir` = `<slug>/<sessionId>/` (the directory next to `<sessionId>.jsonl`).
    /// `parentTranscript` = `<sessionId>.jsonl` (its tail window is read for function_call/result
    /// pairs). `turnStartedAt` = start of the current turn: only calls spawned in this turn are
    /// kept (call time ≥ it); nil means no filter. tailBytes defaults to 1MB: spawn calls must stay
    /// inside the window for the whole turn, and codebuddy tool results often carry large file
    /// contents (observed up to several hundred KB per turn); a 256KB window would drop subagents
    /// mid-turn.
    public static func scan(
        sessionDir: URL,
        parentTranscript: URL?,
        turnStartedAt: Date? = nil,
        tailBytes: Int = 1048576
    ) -> [SubagentInfo] {
        guard let parentTranscript,
              let data = tail(of: parentTranscript, bytes: tailBytes)
        else { return [] }

        struct Spawn {
            var agentType: String
            var description: String
            var prompt: String?
            var startedAt: Date?
        }
        var spawns: [String: Spawn] = [:]   // callId → spawn info
        var order: [String] = []
        var results: [String: Bool] = [:]   // callId → failed or not (only calls that have returned)

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let type = root["type"] as? String
            else { continue }
            switch type {
            case "function_call":
                guard
                    let name = root["name"] as? String,
                    ["TaskCreate", "Agent", "AgentSwarm"].contains(name),
                    let callId = root["callId"] as? String, !callId.isEmpty
                else { continue }
                let ts = CodeBuddyTranscriptDecoder.timestamp(root)
                // Keep only subagents spawned in this turn
                if let turnStartedAt, let ts, ts < turnStartedAt { continue }
                let args = CodeBuddyTranscriptDecoder.toolCall(root)?.args ?? [:]
                let description = (args["description"] as? String)
                    ?? (args["subject"] as? String) ?? ""
                // TaskCreate has no subagent_type field; fall back to the tool name
                let agentType = (args["subagent_type"] as? String)
                    ?? (name == "TaskCreate" ? "task" : "agent")
                if spawns[callId] == nil { order.append(callId) }
                spawns[callId] = Spawn(
                    agentType: agentType, description: description,
                    prompt: args["prompt"] as? String, startedAt: ts)
            case "function_call_result":
                guard let callId = root["callId"] as? String else { continue }
                // The observed terminal status is "completed"; any other present status counts as
                // failed
                if let status = root["status"] as? String {
                    results[callId] = status != "completed"
                }
            default:
                continue
            }
        }
        guard !spawns.isEmpty else { return [] }

        // Build the prompt → subfile index only when an agent is running (saves IO)
        let subagentsDir = sessionDir.appendingPathComponent("subagents", isDirectory: true)
        var transcripts: [(firstPrompt: String, url: URL)]?
        var infos: [SubagentInfo] = []
        for callId in order {
            guard let spawn = spawns[callId] else { continue }
            let status: SubagentInfo.Status
            if let isError = results[callId] {
                status = isError ? .failed : .completed
            } else {
                status = .running
            }

            var currentActivity: String?
            if status == .running, let prompt = spawn.prompt, !prompt.isEmpty {
                if transcripts == nil { transcripts = subagentTranscripts(in: subagentsDir) }
                let needle = String(prompt.prefix(64))
                if let match = transcripts?.first(where: { $0.firstPrompt.hasPrefix(needle) }) {
                    currentActivity = lastToolUse(in: match.url, tailBytes: 32768)
                }
            }

            infos.append(SubagentInfo(
                agentId: callId,
                agentType: spawn.agentType,
                description: spawn.description,
                status: status,
                currentActivity: currentActivity,
                startedAt: spawn.startedAt,
                finishedAt: nil))  // same as the claude scanner: keep nil so snapshots can be deduped
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

    /// First user body of each agent-*.jsonl under subagents/ (used to locate a callId's transcript
    /// by prompt prefix)
    private static func subagentTranscripts(in dir: URL) -> [(firstPrompt: String, url: URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("agent-") && $0.pathExtension == "jsonl" } ?? []
        var out: [(String, URL)] = []
        for file in files {
            guard let head = head(of: file, bytes: 8192),
                  let line = head.split(separator: UInt8(ascii: "\n")).first,
                  let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let text = CodeBuddyTranscriptDecoder.userText(root)
            else { continue }
            out.append((text, file))
        }
        return out
    }

    /// Tool name of the last function_call in a subagent transcript's tail window
    private static func lastToolUse(in url: URL, tailBytes: Int) -> String? {
        guard let data = tail(of: url, bytes: tailBytes) else { return nil }
        var last: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                root["type"] as? String == "function_call",
                let name = root["name"] as? String
            else { continue }
            last = name
        }
        return last
    }

    /// Reads the first bytes of a file (the whole file if shorter)
    private static func head(of url: URL, bytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes), !data.isEmpty else { return nil }
        return data
    }

    /// Reads the last bytes of a file (the whole file if shorter); same tail-window read as
    /// ClaudeSubagentScanner
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
