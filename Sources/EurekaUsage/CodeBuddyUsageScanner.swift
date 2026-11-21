import Foundation
import EurekaKit
import EurekaStore

/// Scans ~/.codebuddy/projects/**/*.jsonl (including `<sessionId>/subagents/agent-*.jsonl`). Schema
/// verified against real sessions (2026-07): tokens sit on `function_call` lines in
/// `providerData.usage` / `message.usage` (observed as camelCase: inputTokens includes cache reads,
/// inputTokensDetails[0].cached_tokens; Claude-style snake_case is the fallback) → usage_records;
/// `function_call` name → tool_calls (Skill/mcp__/Agent classified the same way as the Kimi
/// scanner); user messages (excluding skipRun meta lines) → session_stats prompt count. Subagent
/// tokens are real spend and are attributed to the parent session id; prompts count only in the
/// main session file. Reads incrementally from an inode+offset watermark (jsonl is single-writer
/// append-only, no cross-file duplicate lines, so no dedup_keys).
///
/// WorkBuddy (`dialect: .workbuddy`, `~/.workbuddy/projects`) embeds the same engine; the rules
/// that differ come from `CodeBuddyDialect` (shared with the ingest side): usage is read from every
/// line that carries it (a final step without a tool call keeps it on the assistant message), and
/// prompts are counted only at real turn starts. Scheduled automation runs are counted like any
/// other session: their tokens are real spend, even though the sessions themselves are kept out of
/// history. The per-task working folders WorkBuddy creates (`~/WorkBuddy/<timestamp>`) are
/// attributed to one project named "WorkBuddy" instead of a project per timestamp.
public final class CodeBuddyUsageScanner {
    private let projectsRoot: URL
    private let dialect: CodeBuddyDialect
    private let workspaceRoot: String?
    private let store: EurekaStore
    /// The last slice read left more of the file unread (see `ScanSlices`)
    private var hasMoreSlices = false
    private let projectResolver = ProjectResolver()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Per-file private state (stored in scan_files.extra): session attribution + whether this is
    /// the main session file (prompts count only there)
    private struct FileExtra: Codable {
        var project: String?
        var sessionId: String?
        var isMain: Bool?
    }

    /// projectsRoot is passed in by the caller (app/CLI use `CodeBuddyPaths.projectsRoot()`, tests
    /// use a temp dir) — EurekaUsage does not depend on EurekaIngest, so there is no default here.
    public init(
        projectsRoot: URL, store: EurekaStore,
        dialect: CodeBuddyDialect = .codebuddyCode, workspaceRoot: URL? = nil
    ) {
        self.projectsRoot = projectsRoot
        self.dialect = dialect
        self.workspaceRoot = workspaceRoot.map { $0.standardizedFileURL.path }
        self.store = store
    }

    private func projectName(forCwd cwd: String) -> String? {
        if let workspaceRoot, cwd == workspaceRoot || cwd.hasPrefix(workspaceRoot + "/") {
            return "WorkBuddy"
        }
        return projectResolver.projectName(forCwd: cwd)
    }

    /// Returns the number of usage records added this pass
    @discardableResult
    public func scanOnce() throws -> Int {
        var inserted = 0
        for file in sessionFiles() {
            inserted += try ScanSlices.drain(
                stateKey: file.path, store: store, hasMore: { hasMoreSlices }
            ) {
                hasMoreSlices = false
                return try scanFile(file)
            }
        }
        return inserted
    }

    /// projects/<slug>/*.jsonl (main sessions) + projects/<slug>/<sessionId>/subagents/*.jsonl
    /// (subagents; no mtime filter — the scan_state watermark makes old files with no new data
    /// nearly free)
    private func sessionFiles() -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for projectDir in projectDirs where isDirectory(projectDir) {
            let entries = (try? fm.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for entry in entries {
                if isDirectory(entry) {
                    let subagents = entry.appendingPathComponent("subagents", isDirectory: true)
                    let files = (try? fm.contentsOfDirectory(
                        at: subagents, includingPropertiesForKeys: nil)) ?? []
                    results += files.filter { $0.pathExtension.lowercased() == "jsonl" }
                } else if entry.pathExtension.lowercased() == "jsonl" {
                    results.append(entry)
                }
            }
        }
        return results
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func scanFile(_ url: URL) throws -> Int {
        let path = url.path
        guard let info = JSONLinesReader.fileInfo(path: path) else { return 0 }
        let saved = try store.scanState.fileState(path: path)

        var offset: UInt64 = 0
        var extra = FileExtra()
        if let saved, saved.inode == info.inode, UInt64(saved.offset) <= info.size {
            offset = UInt64(saved.offset)
            if let extraJSON = saved.extra,
               let decoded = try? JSONDecoder().decode(FileExtra.self, from: Data(extraJSON.utf8)) {
                extra = decoded
            }
        }
        if extra.sessionId == nil {
            resolveOwnership(fileURL: url, into: &extra)
        }
        guard info.size > offset else { return 0 }
        guard let chunk = JSONLinesReader.read(path: path, from: offset) else { return 0 }
        hasMoreSlices = !chunk.reachedEnd

        var records: [UsageRecord] = []
        // The engine writes each step's usage once; this only guards a line that repeats it
        var seenSteps: Set<String> = []
        var promptCount = 0
        // Tool/skill calls: each carries its real timestamp (used for MAX of tool_calls.last_ts)
        var toolBumps: [(day: String, kind: String, name: String, ts: Double)] = []

        for line in chunk.lines {
            guard
                let object = try? JSONSerialization.jsonObject(with: line),
                let root = object as? [String: Any],
                let type = root["type"] as? String
            else { continue }
            if extra.project == nil, let cwd = root["cwd"] as? String {
                extra.project = projectName(forCwd: cwd)
            }
            // Real user prompts (codebuddyCode: not a skipRun meta line; workbuddy: a turn start);
            // prompts count only in the main session file
            if extra.isMain == true, dialect.startsTurn(root) {
                promptCount += 1
            }
            if let step = dialect.usage(root),
               step.messageId.map({ seenSteps.insert($0).inserted }) ?? true {
                records.append(UsageRecord(
                    source: dialect.source,
                    // model lives in providerData.model (e.g. "glm-5.2", stored verbatim)
                    model: step.model ?? dialect.unknownModel,
                    project: extra.project,
                    sessionId: extra.sessionId,
                    timestamp: eventDate(root),
                    inputTokens: step.input,
                    outputTokens: step.output,
                    cacheCreationTokens: 0,
                    cacheReadTokens: step.cacheRead))
            }

            switch type {
            case "function_call":
                let date = eventDate(root)
                if let rawName = root["name"] as? String, !rawName.isEmpty {
                    var args = parseArguments(root["arguments"] as? String)
                    let name = dialect.effectiveToolName(name: rawName, args: args)
                    if name != rawName { args = args["params"] as? [String: Any] ?? [:] }
                    let day = Self.dayFormatter.string(from: date)
                    let ts = date.timeIntervalSince1970
                    // kind classification matches the Kimi scanner (keeps skill analytics / plugin
                    // panel consistent across sources)
                    if name == "Skill" {
                        toolBumps.append((day, "skill", (args["skill"] as? String) ?? "?", ts))
                    } else if name.hasPrefix("mcp__") {
                        let comps = name.components(separatedBy: "__").filter { !$0.isEmpty }
                        let server = comps.count >= 2 ? comps[1] : name
                        let tool = comps.count >= 3 ? comps[2...].joined(separator: "__") : ""
                        toolBumps.append((day, "mcp", tool.isEmpty ? server : "\(server).\(tool)", ts))
                    } else if name == "Agent" || name == "AgentSwarm" || name == "Task" {
                        let subagent = (args["subagent_type"] as? String)
                            ?? (args["agentType"] as? String) ?? (args["agent_type"] as? String) ?? "?"
                        toolBumps.append((day, "agent", subagent, ts))
                    } else {
                        toolBumps.append((day, "tool", name, ts))
                    }
                }
            default:
                break
            }
        }

        var inserted = 0
        let extraJSON = String(
            data: (try? JSONEncoder().encode(extra)) ?? Data(), encoding: .utf8)
        try store.scanState.transaction {
            inserted = try store.usage.insert(records)
            for bump in toolBumps {
                try store.toolCalls.bump(
                    day: bump.day, source: dialect.source, kind: bump.kind, name: bump.name,
                    ts: bump.ts)
            }
            try store.scanState.setFileState(
                path: path,
                .init(inode: info.inode, offset: Int64(chunk.newOffset), extra: extraJSON))
            if extra.isMain == true, let sessionId = extra.sessionId {
                try store.sessionStats.recordPrompts(
                    path: path, sessionId: sessionId, count: promptCount, reset: offset == 0)
            }
        }
        return inserted
    }

    /// Line time: epoch-milliseconds `timestamp` (>1e12 means milliseconds); falls back to now when
    /// missing
    private func eventDate(_ root: [String: Any]) -> Date {
        if let number = root["timestamp"] as? NSNumber {
            let value = number.doubleValue
            return Date(timeIntervalSince1970: value > 1e12 ? value / 1000 : value)
        }
        return Date()
    }

    /// arguments is a JSON string (e.g. `{"skill":"tdd"}`); a parse failure is treated as empty
    private func parseArguments(_ raw: String?) -> [String: Any] {
        guard let raw,
              let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8))
        else { return [:] }
        return object as? [String: Any] ?? [:]
    }

    private func intValue(_ dict: [String: Any], _ keys: [String]) -> Int {
        for key in keys {
            if let number = dict[key] as? NSNumber { return number.intValue }
        }
        return 0
    }

    /// Session attribution: main session file = <slug>/<sessionId>.jsonl (the file name stem is the
    /// session id); subagent file = <slug>/<sessionId>/subagents/agent-*.jsonl (the parent dir name
    /// is the session id; tokens go to the parent session, prompts are not counted)
    private func resolveOwnership(fileURL: URL, into extra: inout FileExtra) {
        let parent = fileURL.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" {
            extra.sessionId = parent.deletingLastPathComponent().lastPathComponent
            extra.isMain = false
        } else {
            extra.sessionId = fileURL.deletingPathExtension().lastPathComponent
            extra.isMain = true
        }
    }
}
