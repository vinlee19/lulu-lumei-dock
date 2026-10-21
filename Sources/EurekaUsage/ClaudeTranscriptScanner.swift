import Foundation
import EurekaKit
import EurekaStore

/// Scans usage from assistant lines in ~/.claude/projects/*/*.jsonl. Key invariant: **global dedup
/// across files** (requestId + message.id) -- streaming writes repeat the same usage many times,
/// and resume/fork copies old lines into new files; measured locally: 1803 duplicate pairs in a
/// single file. Without dedup, cost is inflated several times over.
public final class ClaudeTranscriptScanner {
    public static func defaultProjectsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CLAUDE_PROJECTS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    private let projectsRoot: URL
    private let store: EurekaStore
    /// The last slice read left more of the file unread (see `ScanSlices`)
    private var hasMoreSlices = false
    private let projectResolver = ProjectResolver()
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    public init(projectsRoot: URL, store: EurekaStore) {
        self.projectsRoot = projectsRoot
        self.store = store
    }

    /// Returns the number of usage records added in this pass. Enumeration must be **recursive**:
    /// subagent/team sessions are nested in <project>/<session>/subagents/*.jsonl (measured
    /// locally: 5x as many nested files as top-level ones; missing them under-counts usage by
    /// 15-30%).
    @discardableResult
    public func scanOnce() throws -> Int {
        var inserted = 0
        let enumerator = FileManager.default.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            if item.pathExtension == "jsonl" {
                // One pool per file: the bridged objects from per-line JSON parsing are
                // autoreleased, and a full rescan (after a migration clears scan_files) without
                // draining builds up GB-level peaks
                inserted += try ScanSlices.drain(
                stateKey: item.path, store: store, hasMore: { hasMoreSlices }
            ) {
                hasMoreSlices = false
                return try scanFile(item)
            }
            }
        }
        return inserted
    }

    private func scanFile(_ url: URL) throws -> Int {
        let path = url.path
        guard let info = JSONLinesReader.fileInfo(path: path) else { return 0 }
        let saved = try store.scanState.fileState(path: path)

        var offset: UInt64 = 0
        if let saved, saved.inode == info.inode, UInt64(saved.offset) <= info.size {
            offset = UInt64(saved.offset)
        }
        guard info.size > offset else { return 0 }
        guard let chunk = JSONLinesReader.read(path: path, from: offset) else { return 0 }
        hasMoreSlices = !chunk.reachedEnd

        // Merge within the batch: streaming duplicates of the same key have increasing output; keep
        // the max (final) value; count real user prompts along the way (conversation count, zero
        // extra IO)
        var merged: [String: UsageRecord] = [:]
        var order: [String] = []
        var promptCount = 0
        // Tool/skill/plugin calls: **accumulated per tool_use id**, not merged by the assistant
        // dedup key -- Claude Code writes each content block as its own line but they share one
        // (requestId, message.id); overwriting by key lets a later Bash line evict a Skill line
        // from the same message (measured locally: 10 of 78 skill calls lost).
        var toolCalls: [(
            id: String, kind: String, name: String, day: String, ts: Double, tokens: Int
        )] = []
        var seenToolIds: Set<String> = []
        // Slash commands: (uuid, day, name), counted after dedup on s:<uuid>
        var commands: [(uuid: String, day: String, name: String)] = []
        for line in chunk.lines {
            guard
                let object = try? JSONSerialization.jsonObject(with: line),
                let root = object as? [String: Any]
            else { continue }
            if Self.isRealPrompt(root) { promptCount += 1 }
            if let command = Self.extractCommand(root) {
                let day = (root["timestamp"] as? String)
                    .flatMap { Self.isoFormatter.date(from: $0) }
                    .map { Self.dayFormatter.string(from: $0) }
                    ?? Self.dayFormatter.string(from: Date())
                commands.append((command.uuid, day, command.name))
            }
            guard let parsed = Self.parseAssistantLine(root) else { continue }
            let key = parsed.key
            var record = parsed.record
            // Project names are grouped by repo root (sessions in subdirectories/submodules count
            // under the repo name)
            record.project = projectResolver.projectName(forCwd: record.project) ?? record.project
            if let message = root["message"] as? [String: Any] {
                // Token at trigger time = token total of that assistant line (≈ context size at
                // call time; Claude only); with several tool_use blocks on one line, each call gets
                // the line's total; overlap in the skill case is negligible
                let lineTokens = record.inputTokens + record.outputTokens
                    + record.cacheCreationTokens + record.cacheReadTokens
                let day = Self.dayFormatter.string(from: record.timestamp)
                let ts = record.timestamp.timeIntervalSince1970
                for call in Self.extractToolCalls(message) {
                    // A tool_use without an id can't be deduped (a rescan would double it) →
                    // conservatively not counted
                    guard let id = call.id, !id.isEmpty else { continue }
                    guard seenToolIds.insert(id).inserted else { continue }  // Count the same id only once within a file
                    toolCalls.append((id, call.kind, call.name, day, ts, lineTokens))
                }
            }
            if let prior = merged[key] {
                if record.outputTokens > prior.outputTokens {
                    merged[key] = record
                }
            } else {
                merged[key] = record
                order.append(key)
            }
        }

        var newCount = 0
        // Session = file (the filename is the session id); conversations are counted per file,
        // unaffected by attribution rewrites
        let sessionId = url.deletingPathExtension().lastPathComponent
        // Session that call counts are attributed to: subagent transcripts go to the parent session
        // (see attributionSessionId)
        let callSessionId = Self.attributionSessionId(for: url, root: projectsRoot)
        try store.scanState.transaction {
            // Dedup must be global across files: persisted in the dedup_keys table
            let existing = try store.scanState.existingDedupKeys(order)
            let now = Date()
            for key in order {
                guard let record = merged[key] else { continue }
                if let entry = existing[key] {
                    // Already recorded: if the scan caught a stream mid-way, a partial output was
                    // stored; backfill the larger value
                    if record.outputTokens > entry.outputTokens, let recordId = entry.recordId {
                        try store.usage.updateOutputTokens(
                            recordId: recordId, outputTokens: record.outputTokens)
                        try store.scanState.upsertDedupKey(
                            key, recordId: recordId,
                            outputTokens: record.outputTokens, at: now)
                    }
                } else {
                    let recordId = try store.usage.insertReturningId(record)
                    try store.scanState.upsertDedupKey(
                        key, recordId: recordId,
                        outputTokens: record.outputTokens, at: now)
                    newCount += 1
                }
            }
            // Tool/skill/plugin/subagent calls: deduped across files by tc:<tool_use id>,
            // **decoupled from message-level usage dedup** -- hanging it on the "first insert"
            // branch misses calls: if one pass only reads a message's thinking/text lines it
            // consumes the message-level key, and when the next pass reads that message's tool_use
            // line it takes the backfill branch, so the call is never attributed.
            if !toolCalls.isEmpty {
                let callKeys = toolCalls.map { "tc:\($0.id)" }
                let existingCalls = try store.scanState.existingDedupKeys(callKeys)
                for call in toolCalls {
                    let dkey = "tc:\(call.id)"
                    guard existingCalls[dkey] == nil else { continue }
                    try store.toolCalls.bump(
                        day: call.day, source: .claude, kind: call.kind, name: call.name,
                        ts: call.ts, tokens: call.tokens, session: callSessionId)
                    try store.scanState.upsertDedupKey(
                        dkey, recordId: nil, outputTokens: 0, at: now)
                }
            }
            // Slash commands: deduped across files by s:<uuid>; only new keys are counted
            if !commands.isEmpty {
                let commandKeys = commands.map { "s:\($0.uuid)" }
                let existingCommands = try store.scanState.existingDedupKeys(commandKeys)
                for command in commands {
                    let dkey = "s:\(command.uuid)"
                    guard existingCommands[dkey] == nil else { continue }
                    try store.toolCalls.bump(
                        day: command.day, source: .claude, kind: "command", name: command.name,
                        session: callSessionId)
                    try store.scanState.upsertDedupKey(
                        dkey, recordId: nil, outputTokens: 0, at: now)
                }
            }
            try store.scanState.setFileState(
                path: path,
                .init(inode: info.inode, offset: Int64(chunk.newOffset)))
            // offset==0 means a full rescan → overwrite instead of accumulate
            try store.sessionStats.recordPrompts(
                path: path,
                sessionId: sessionId,
                count: promptCount,
                reset: offset == 0)
        }
        return newCount
    }

    /// Session id that call counts are attributed to: subagent transcripts (`<parent
    /// session>/subagents/**/agent-*.jsonl`) go to the **parent session**. The filename-derived
    /// `agent-<hash>` is not a real session; `ClaudeSessionIndexer` only enumerates one level and
    /// can never resolve it, so using it for lookup yields a dead link. The parent session is the
    /// directory above `subagents` -- note that under subagents there can be another
    /// `workflows/wf_<id>/` level (4 local directories look like this), so subagents must be
    /// located by path component; looking only at the parent directory name misses this shape. The
    /// search starts below the project root, so a root path that itself contains a directory of the
    /// same name isn't misread.
    static func attributionSessionId(for url: URL, root: URL) -> String {
        let fileName = url.deletingPathExtension().lastPathComponent
        let components = url.pathComponents
        let rootDepth = root.pathComponents.count
        guard components.count > rootDepth,
              let marker = components[rootDepth...].firstIndex(of: "subagents"),
              marker > rootDepth
        else { return fileName }
        return components[marker - 1]
    }

    /// tool_use block of an assistant line → (id, kind, name): Skill→(skill, skill name) / mcp__
    /// prefix→(mcp, server.tool) / Task|Agent→(agent, subagent type) / everything else→(tool, tool
    /// name). id is the tool_use block's own unique identifier (`toolu_xxx`); call counts dedup on
    /// it; nil when missing.
    static func extractToolCalls(
        _ message: [String: Any]
    ) -> [(id: String?, kind: String, name: String)] {
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var result: [(String?, String, String)] = []
        for block in blocks where block["type"] as? String == "tool_use" {
            guard let name = block["name"] as? String, !name.isEmpty else { continue }
            let id = block["id"] as? String
            let input = block["input"] as? [String: Any]
            if name == "Skill" {
                result.append((id, "skill", (input?["skill"] as? String) ?? "?"))
            } else if name.hasPrefix("mcp__") {
                let comps = name.components(separatedBy: "__").filter { !$0.isEmpty }
                var server = comps.count >= 2 ? comps[1] : name
                if server.hasPrefix("claude_ai_") {
                    server = String(server.dropFirst("claude_ai_".count))
                }
                let tool = comps.count >= 3 ? comps[2...].joined(separator: "__") : ""
                result.append((id, "mcp", tool.isEmpty ? server : "\(server).\(tool)"))
            } else if name == "Task" || name == "Agent" {
                result.append((id, "agent", (input?["subagent_type"] as? String) ?? "?"))
            } else {
                result.append((id, "tool", name))
            }
        }
        return result
    }

    /// Slash command embedded in a user line: `<command-name>/xx</command-name>` → (uuid, command
    /// name)
    static func extractCommand(_ root: [String: Any]) -> (uuid: String, name: String)? {
        guard root["type"] as? String == "user",
              root["isMeta"] as? Bool != true,
              let uuid = root["uuid"] as? String,
              let message = root["message"] as? [String: Any],
              let content = message["content"] as? String,
              let start = content.range(of: "<command-name>"),
              let end = content.range(
                of: "</command-name>", range: start.upperBound..<content.endIndex)
        else { return nil }
        let name = String(content[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (uuid, name)
    }

    /// Real user prompt (conversation turn): non-meta, and content is a string (tool_result is an
    /// array)
    static func isRealPrompt(_ root: [String: Any]) -> Bool {
        guard root["type"] as? String == "user",
              root["isMeta"] as? Bool != true,
              let message = root["message"] as? [String: Any]
        else { return false }
        return message["content"] is String
    }

    /// assistant line → (dedup key, usage record); synthetic error lines and non-assistant lines
    /// return nil
    static func parseAssistantLine(_ root: [String: Any]) -> (key: String, record: UsageRecord)? {
        guard
            root["type"] as? String == "assistant",
            let message = root["message"] as? [String: Any],
            let model = message["model"] as? String,
            model != "<synthetic>",
            let usage = message["usage"] as? [String: Any]
        else { return nil }

        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cache1h = (usage["cache_creation"] as? [String: Any])?[
            "ephemeral_1h_input_tokens"] as? Int ?? 0
        // All-zero lines (e.g. pure tool-result replies) are not recorded
        if input == 0 && output == 0 && cacheCreation == 0 && cacheRead == 0 { return nil }

        let requestId = root["requestId"] as? String
        let messageId = message["id"] as? String
        let key: String
        if let requestId, let messageId {
            key = "c:\(requestId):\(messageId)"
        } else {
            // Lines missing identifiers fall back to a uuid key (no cross-file dedup, but no data
            // loss either)
            key = "u:\(root["uuid"] as? String ?? UUID().uuidString)"
        }

        let timestamp = (root["timestamp"] as? String).flatMap {
            isoFormatter.date(from: $0)
        } ?? Date()

        return (key, UsageRecord(
            source: .claude,
            model: model,
            // Stash the raw cwd; scanFile groups it into a repo name via ProjectResolver
            project: root["cwd"] as? String,
            sessionId: root["sessionId"] as? String,
            timestamp: timestamp,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheCreation1hTokens: cache1h,
            cacheReadTokens: cacheRead
        ))
    }
}
