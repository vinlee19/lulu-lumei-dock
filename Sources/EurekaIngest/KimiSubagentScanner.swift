import Foundation
import EurekaKit

/// Scans the subagents of one Kimi session (pure function, easy to unit test). Lightweight
/// snapshot: reads only the head + a small tail window of each agent's wire.jsonl, no incremental
/// tail (tailing the main wire belongs to KimiWireTailer; feeding subagent wires into the event
/// stream would create phantom tasks).
///
/// On-disk conventions (surveyed 2026-07, ~/.kimi-code):
/// - `agents/<id>/wire.jsonl` (id != "main") = one subagent; the parent `state.json` gives the
///   type in `agents.<id>.type` ("sub") and the session start in `createdAt`.
/// - The description is the body of the first turn.prompt in the subagent wire head (summarized
///   after stripping the `<git-context>` wrapper; note a subagent prompt's origin.kind is
///   system_trigger, so the decoder's user-turn check cannot be used).
/// - Status: an unfinished turn / in-turn heartbeat in the tail window + a live wire mtime (written
///   within 30 minutes by default) = running; a quiet mtime means the process died midway, so it
///   is closed out as completed; final-turn finishReason=error → failed.
/// - Current tool = name of the last tool.call in the tail window.
public enum KimiSubagentScanner {
    /// `sessionDir` = `sessions/<ws>/<session>/` (the directory holding state.json and agents/).
    /// `turnStartedAt` = start of the main session's current turn: subagents whose wire was created
    /// earlier are leftovers from an old turn and are filtered out.
    /// `liveWindow` = write-freshness window for "still alive" (a dead session's turn never
    /// finishes, so this keeps it from staying running forever).
    /// headBytes defaults to 64KB: a single wire prelude line (config.update's systemPrompt etc.)
    /// can reach tens of KB; surveyed first turn.prompt lines fall within ~40KB.
    public static func scan(
        sessionDir: URL,
        turnStartedAt: Date? = nil,
        now: Date = Date(),
        liveWindow: TimeInterval = 1800,
        headBytes: Int = 65536,
        tailBytes: Int = 32768
    ) -> [SubagentInfo] {
        let fm = FileManager.default
        let agentsDir = sessionDir.appendingPathComponent("agents", isDirectory: true)
        let agentDirs = ((try? fm.contentsOfDirectory(
            at: agentsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter {
                $0.lastPathComponent != "main"
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
        guard !agentDirs.isEmpty else { return [] }

        let types = agentTypes(sessionDir: sessionDir)
        var infos: [SubagentInfo] = []
        for dir in agentDirs {
            let wire = dir.appendingPathComponent("wire.jsonl")
            guard
                let values = try? wire.resourceValues(
                    forKeys: [.creationDateKey, .contentModificationDateKey]),
                let mtime = values.contentModificationDate
            else { continue }
            let createdAt = values.creationDate
            // Keep only subagents spawned in this turn (wire created after the prompt)
            if let turnStartedAt, let createdAt, createdAt < turnStartedAt { continue }

            let firstPrompt = head(of: wire, bytes: headBytes).flatMap(firstPromptText)
            var lastStarted: Date?
            var lastFinished: (at: Date, isError: Bool)?
            var lastProgress: Date?  // latest in-turn heartbeat (tool.call / intermediate step)
            var lastTool: String?
            if let data = tail(of: wire, bytes: tailBytes) {
                for line in data.split(separator: UInt8(ascii: "\n")) {
                    guard
                        let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                    else { continue }
                    if let (name, _) = KimiWireDecoder.toolCall(root) { lastTool = name }
                    for event in KimiWireDecoder.decode(root: root, sessionId: "", cwd: nil) {
                        switch event.kind {
                        case .taskStarted:
                            lastStarted = event.timestamp
                        case .taskFinished(let outcome, _, _):
                            lastFinished = (event.timestamp, outcome == .error)
                        case .activity, .waiting, .toolPending, .compacting:
                            lastProgress = event.timestamp
                        default:
                            break
                        }
                    }
                }
            }

            let status: SubagentInfo.Status
            let fresh = now.timeIntervalSince(mtime) < liveWindow
            let openTurn = lastStarted != nil
                && (lastFinished.map { $0.at < lastStarted! } ?? true)
            let activeProgress = lastProgress != nil
                && (lastFinished.map { $0.at < lastProgress! } ?? true)
            if openTurn || activeProgress {
                // Turn not finished: wire still being written = running; quiet = process died
                // midway, close out as completed
                status = fresh ? .running : .completed
            } else if let finished = lastFinished {
                status = finished.isError ? .failed : .completed
            } else {
                // No turn trace in the tail window: alive = just spawned; quiet = ancient, treat as
                // completed
                status = fresh ? .running : .completed
            }

            infos.append(SubagentInfo(
                agentId: dir.lastPathComponent,
                agentType: types[dir.lastPathComponent] ?? "sub",
                description: firstPrompt.flatMap(descriptionText) ?? "",
                status: status,
                currentActivity: status == .running ? lastTool : nil,
                startedAt: createdAt ?? lastStarted,
                finishedAt: nil))  // same as the claude scanner: keep nil so snapshots can be deduped
        }

        // Stable sort: earlier start first; entries without a time fall back to agentId
        return infos.sorted {
            switch ($0.startedAt, $1.startedAt) {
            case let (l?, r?) where l != r: return l < r
            default: return $0.agentId < $1.agentId
            }
        }
    }

    // MARK: - Parsing

    /// The agents.<id>.type table from state.json (empty on read failure; the caller falls back to
    /// "sub")
    private static func agentTypes(sessionDir: URL) -> [String: String] {
        let url = sessionDir.appendingPathComponent("state.json")
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let agents = root["agents"] as? [String: Any]
        else { return [:] }
        var map: [String: String] = [:]
        for (id, entry) in agents {
            if let type = (entry as? [String: Any])?["type"] as? String, !type.isEmpty {
                map[id] = type
            }
        }
        return map
    }

    /// Body of the first turn.prompt in the wire head (input=[{type:text,text}] joined).
    /// KimiWireDecoder.promptText cannot be used: a subagent's first turn has origin.kind
    /// system_trigger(name=subagent), which the decoder's user-turn check filters out.
    private static func firstPromptText(head: Data) -> String? {
        for line in head.split(separator: UInt8(ascii: "\n")) {
            guard
                let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                root["type"] as? String == "turn.prompt",
                let blocks = root["input"] as? [[String: Any]]
            else { continue }
            let text = blocks
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Spawn prompt → one-line description shown on the island: strip the
    /// `<git-context>…</git-context>` prefix and the leading "Thoroughness: …." sentence from the
    /// Agent tool template, then summarize
    static func descriptionText(_ prompt: String) -> String? {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<git-context>"),
           let close = text.range(of: "</git-context>") {
            text = String(text[close.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("Thoroughness: "),
           let dot = text.firstIndex(of: "."), text.distance(from: text.startIndex, to: dot) < 40 {
            text = String(text[text.index(after: dot)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return summarizeTitle(text)
    }

    /// Reads the head bytes of a file (the whole file if shorter)
    private static func head(of url: URL, bytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes), !data.isEmpty else { return nil }
        return data
    }

    /// Reads the tail bytes of a file (the whole file if shorter), same tail-window read as
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
