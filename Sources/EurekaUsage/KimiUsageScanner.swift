import Foundation
import EurekaKit
import EurekaStore

/// Scans ~/.kimi-code/sessions/<ws>/<session>/agents/<agentId>/wire.jsonl. Schema verified against
/// real sessions: `usage.record` carries the model + four token fields
/// (inputOther/output/inputCacheRead/inputCacheCreation, each the delta for that LLM request) →
/// usage_records; loop event `tool.call` (Skill/mcp__/Agent…) → tool_calls;
/// `turn.prompt`(origin=user) → session_stats. Covers every agent (subagent tokens are real spend,
/// attributed to the parent session id); prompts count only in main. Reads incrementally from an
/// inode+offset watermark (wire.jsonl is single-writer append-only, no cross-file duplicate lines,
/// so no dedup_keys).
public final class KimiUsageScanner {
    private let sessionsRoot: URL
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
    /// the main agent (prompts count only in main)
    private struct FileExtra: Codable {
        var project: String?
        var sessionId: String?
        var isMain: Bool?
    }

    /// sessionsRoot is passed in by the caller (app/CLI use `KimiPaths.sessionsRoot()`, tests use a
    /// temp dir) — EurekaUsage does not depend on EurekaIngest, so there is no default here.
    public init(sessionsRoot: URL, store: EurekaStore) {
        self.sessionsRoot = sessionsRoot
        self.store = store
    }

    /// Returns the number of usage records added this pass
    @discardableResult
    public func scanOnce() throws -> Int {
        var inserted = 0
        for file in wireFiles() {
            inserted += try ScanSlices.drain(
                stateKey: file.path, store: store, hasMore: { hasMoreSlices }
            ) {
                hasMoreSlices = false
                return try scanFile(file)
            }
        }
        return inserted
    }

    /// All of sessions/<ws>/<session>/agents/<agentId>/wire.jsonl (three-level directory walk; no
    /// mtime filter — the scan_state watermark makes old files with no new data nearly free)
    private func wireFiles() -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let workspaceDirs = (try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for workspaceDir in workspaceDirs where isDirectory(workspaceDir) {
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: workspaceDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sessionDir in sessionDirs where isDirectory(sessionDir) {
                let agentsDir = sessionDir.appendingPathComponent("agents", isDirectory: true)
                let agentDirs = (try? fm.contentsOfDirectory(
                    at: agentsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                for agentDir in agentDirs where isDirectory(agentDir) {
                    let wire = agentDir.appendingPathComponent("wire.jsonl")
                    if fm.fileExists(atPath: wire.path) { results.append(wire) }
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
            resolveOwnership(wireURL: url, into: &extra)
        }
        guard info.size > offset else { return 0 }
        guard let chunk = JSONLinesReader.read(path: path, from: offset) else { return 0 }
        hasMoreSlices = !chunk.reachedEnd

        var records: [UsageRecord] = []
        var promptCount = 0
        // Tool/skill calls: each carries its real timestamp (used for MAX of tool_calls.last_ts)
        var toolBumps: [(day: String, kind: String, name: String, ts: Double)] = []

        for line in chunk.lines {
            guard
                let object = try? JSONSerialization.jsonObject(with: line),
                let root = object as? [String: Any],
                let type = root["type"] as? String
            else { continue }

            switch type {
            case "turn.prompt":
                // Real user prompts (origin=user); prompts count only in the main agent
                if extra.isMain == true,
                   (root["origin"] as? [String: Any])?["kind"] as? String ?? "user" == "user" {
                    promptCount += 1
                }

            case "usage.record":
                guard let usage = root["usage"] as? [String: Any] else { continue }
                let input = usage["inputOther"] as? Int ?? 0
                let output = usage["output"] as? Int ?? 0
                let cacheRead = usage["inputCacheRead"] as? Int ?? 0
                let cacheCreation = usage["inputCacheCreation"] as? Int ?? 0
                guard input > 0 || output > 0 || cacheRead > 0 || cacheCreation > 0 else { continue }
                records.append(UsageRecord(
                    source: .kimi,
                    // model is on the event itself (e.g. "kimi-code/k3", stored verbatim with its
                    // prefix; pricing matches by prefix)
                    model: (root["model"] as? String) ?? "kimi-code/unknown",
                    project: extra.project,
                    sessionId: extra.sessionId,
                    timestamp: eventDate(root),
                    inputTokens: input,
                    outputTokens: output,
                    cacheCreationTokens: cacheCreation,
                    cacheReadTokens: cacheRead))

            case "context.append_loop_event":
                guard let inner = root["event"] as? [String: Any],
                      inner["type"] as? String == "tool.call",
                      let name = inner["name"] as? String, !name.isEmpty
                else { continue }
                let args = inner["args"] as? [String: Any]
                let date = eventDate(root)
                let day = Self.dayFormatter.string(from: date)
                let ts = date.timeIntervalSince1970
                // kind classification matches the Claude scanner (keeps skill analytics / plugin
                // panel consistent across sources)
                if name == "Skill" {
                    toolBumps.append((day, "skill", (args?["skill"] as? String) ?? "?", ts))
                } else if name.hasPrefix("mcp__") {
                    let comps = name.components(separatedBy: "__").filter { !$0.isEmpty }
                    let server = comps.count >= 2 ? comps[1] : name
                    let tool = comps.count >= 3 ? comps[2...].joined(separator: "__") : ""
                    toolBumps.append((day, "mcp", tool.isEmpty ? server : "\(server).\(tool)", ts))
                } else if name == "Agent" || name == "AgentSwarm" || name == "Task" {
                    let subagent = (args?["subagent_type"] as? String)
                        ?? (args?["agentType"] as? String) ?? (args?["agent_type"] as? String) ?? "?"
                    toolBumps.append((day, "agent", subagent, ts))
                } else {
                    toolBumps.append((day, "tool", name, ts))
                }

            default:
                break
            }
        }

        var inserted = 0
        let extraJSON = String(
            data: (try? JSONEncoder().encode(extra)) ?? Data(), encoding: .utf8)
        try store.scanState.transaction {
            try store.usage.insert(records)
            inserted = records.count
            for bump in toolBumps {
                try store.toolCalls.bump(
                    day: bump.day, source: .kimi, kind: bump.kind, name: bump.name,
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

    /// Line time: epoch-milliseconds `time` (>1e12 means milliseconds); falls back to now when
    /// missing
    private func eventDate(_ root: [String: Any]) -> Date {
        if let number = root["time"] as? Double {
            return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
        }
        return Date()
    }

    /// Session attribution: wire.jsonl ← <agentId> ← agents ← session_<uuid> (the dir name is the
    /// session id, consistent with KimiSessionIndexer); workDir is read once from state.json →
    /// project name
    private func resolveOwnership(wireURL: URL, into extra: inout FileExtra) {
        let agentDir = wireURL.deletingLastPathComponent()
        let sessionDir = agentDir
            .deletingLastPathComponent()   // agents/
            .deletingLastPathComponent()   // session_<uuid>/
        extra.sessionId = sessionDir.lastPathComponent
        extra.isMain = agentDir.lastPathComponent == "main"
        let stateURL = sessionDir.appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: stateURL),
           let object = try? JSONSerialization.jsonObject(with: data),
           let root = object as? [String: Any],
           let workDir = root["workDir"] as? String {
            extra.project = projectResolver.projectName(forCwd: workDir)
        }
    }
}
