import Foundation
import EurekaKit
import EurekaStore

/// Scans ~/.zcode/cli/rollout/model-io-sess_<id>.jsonl (the model IO log). Schema verified against
/// real sessions (2026-08): each line is one model request `type:"model_io"`, and `response.usage`
/// has four token fields (inputTokens/outputTokens/cacheReadTokens/cacheWriteTokens) with **OpenAI
/// semantics**: inputTokens includes cache reads (measured cacheReadTokens is a subset of
/// inputTokens) -> subtracted before storing, to match the ledger convention (inputTokens =
/// non-cached input); otherwise tokens/cost would be double-counted (same case as CodeBuddy).
/// `response.modelId` looks like "glm-5.3"; `startedAt` is ISO8601. Tokens in subagent files
/// (sess_subagent_*) are real spend and are collected too (attributed to that subsession's id).
/// `response.toolCalls[].name` -> tool_calls. Reads incrementally from an inode+offset watermark
/// (single append-only writer, so no dedup_keys needed); cwd/project attribution is looked up
/// lazily from the db's session table (directory column, once per file). Prompt counting: see
/// `recordPromptCounts()` -- absolute aggregation over the db message table (same as opencode).
public final class ZcodeUsageScanner {
    private let rolloutRoot: URL
    private let dbPath: URL
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

    /// Per-file private state (stored in scan_files.extra): the session's project name (cwd -> repo
    /// root)
    private struct FileExtra: Codable {
        var project: String?
    }

    /// rolloutRoot/dbPath are supplied by the caller (app/CLI use `ZcodePaths.*()`, tests use a
    /// temp dir) -- EurekaUsage does not depend on EurekaIngest, so there are no defaults here.
    public init(rolloutRoot: URL, dbPath: URL, store: EurekaStore) {
        self.rolloutRoot = rolloutRoot
        self.dbPath = dbPath
        self.store = store
    }

    /// Returns the number of usage records added in this pass
    @discardableResult
    public func scanOnce() throws -> Int {
        var inserted = 0
        for file in rolloutFiles() {
            inserted += try ScanSlices.drain(
                path: file.path, store: store, hasMore: { hasMoreSlices }
            ) {
                hasMoreSlices = false
                return try scanFile(file)
            }
        }
        return inserted
    }

    /// Every model-io-*.jsonl under rollout/ (not filtered by mtime -- the scan_state watermark
    /// makes old files with no new data nearly free)
    private func rolloutFiles() -> [URL] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(
            at: rolloutRoot, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("model-io-") }
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
        // Session id parsed from the file name (model-io-sess_xxx.jsonl -> sess_xxx)
        guard let sessionId = Self.sessionId(fileName: url.lastPathComponent) else { return 0 }
        if extra.project == nil {
            extra.project = projectFor(sessionId: sessionId)
        }
        guard info.size > offset else { return 0 }
        guard let chunk = JSONLinesReader.read(path: path, from: offset) else { return 0 }
        hasMoreSlices = !chunk.reachedEnd

        var records: [UsageRecord] = []
        var toolBumps: [(day: String, kind: String, name: String, ts: Double)] = []
        let isoFraction = ISO8601DateFormatter()
        isoFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        for line in chunk.lines {
            guard
                let object = try? JSONSerialization.jsonObject(with: line),
                let root = object as? [String: Any],
                root["type"] as? String == "model_io",
                let response = root["response"] as? [String: Any]
            else { continue }

            // Usage: response.usage (all zeros / empty object = an error line or an in-progress
            // line; skipped)
            if let dict = response["usage"] as? [String: Any] {
                let rawInput = dict["inputTokens"] as? Int ?? 0
                let output = dict["outputTokens"] as? Int ?? 0
                let cacheRead = dict["cacheReadTokens"] as? Int ?? 0
                let cacheWrite = dict["cacheWriteTokens"] as? Int ?? 0
                // inputTokens includes cache reads (OpenAI semantics) -> subtract; the ledger keeps
                // them in separate columns
                let input = max(0, rawInput - cacheRead)
                if input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0 {
                    let model = ((response["modelId"] as? String)
                        ?? (root["model"] as? [String: Any])?["modelId"] as? String
                        ?? "glm-unknown").lowercased()
                    let timestamp = (root["startedAt"] as? String).flatMap {
                        isoFraction.date(from: $0) ?? isoPlain.date(from: $0)
                    } ?? Date()
                    records.append(UsageRecord(
                        source: .zcode,
                        model: model,
                        project: extra.project,
                        sessionId: sessionId,
                        timestamp: timestamp,
                        inputTokens: input,
                        outputTokens: output,
                        cacheCreationTokens: cacheWrite,
                        cacheReadTokens: cacheRead,
                        // model.providerId looks like `builtin:bigmodel` (the alias table maps it
                        // to Zhipu's pay-as-you-go price)
                        provider: ((root["model"] as? [String: Any])?["providerId"] as? String)?
                            .lowercased()))
                }
            }

            // Tool calls: response.toolCalls[].name (kind classification matches the kimi scanner)
            if let calls = response["toolCalls"] as? [[String: Any]] {
                let date = (root["startedAt"] as? String).flatMap {
                    isoFraction.date(from: $0) ?? isoPlain.date(from: $0)
                } ?? Date()
                let day = Self.dayFormatter.string(from: date)
                let ts = date.timeIntervalSince1970
                for call in calls {
                    guard let name = call["name"] as? String, !name.isEmpty else { continue }
                    let args = call["input"] as? [String: Any]
                    if name == "Skill" {
                        toolBumps.append((day, "skill", (args?["skill"] as? String) ?? "?", ts))
                    } else if name.hasPrefix("mcp__") {
                        let comps = name.components(separatedBy: "__").filter { !$0.isEmpty }
                        let server = comps.count >= 2 ? comps[1] : name
                        let tool = comps.count >= 3 ? comps[2...].joined(separator: "__") : ""
                        toolBumps.append((day, "mcp", tool.isEmpty ? server : "\(server).\(tool)", ts))
                    } else if name == "Agent" || name == "Task" || name.hasPrefix("Agent_") {
                        let subagent = (args?["subagent_type"] as? String)
                            ?? (args?["description"] as? String) ?? "?"
                        toolBumps.append((day, "agent", subagent, ts))
                    } else {
                        toolBumps.append((day, "tool", name, ts))
                    }
                }
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
                    day: bump.day, source: .zcode, kind: bump.kind, name: bump.name,
                    ts: bump.ts)
            }
            try store.scanState.setFileState(
                path: path,
                .init(inode: info.inode, offset: Int64(chunk.newOffset), extra: extraJSON))
        }
        return inserted
    }

    /// `model-io-sess_xxx.jsonl` -> `sess_xxx`
    static func sessionId(fileName: String) -> String? {
        guard fileName.hasPrefix("model-io-"), fileName.hasSuffix(".jsonl") else { return nil }
        let body = String(fileName.dropFirst("model-io-".count).dropLast(".jsonl".count))
        return body.isEmpty ? nil : body
    }

    /// Per-session user prompt count: absolute aggregation over the db message table by
    /// `json_extract(data,'$.role')='user'`, written with `<db>#<sessionId>` as the path and
    /// reset:true overwrite (same as opencode: independent of the watermark, rescans are
    /// idempotent). Silently skipped when the db is missing or the table doesn't exist.
    public func recordPromptCounts() throws {
        guard let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return }
        let rows = (try? db.query("""
            SELECT session_id, COUNT(*) FROM message
            WHERE json_extract(data, '$.role') = 'user'
            GROUP BY session_id
            """) { row -> (String, Int) in (row.text(0) ?? "", Int(row.int(1))) }) ?? []
        guard !rows.isEmpty else { return }
        try store.scanState.transaction {
            for (sessionId, count) in rows where !sessionId.isEmpty {
                try store.sessionStats.recordPrompts(
                    path: "\(dbPath.path)#\(sessionId)", sessionId: sessionId,
                    count: count, reset: true)
            }
        }
    }

    /// Session cwd -> project name (one read-only lookup of session.directory in the db; empty when
    /// the db doesn't exist)
    private func projectFor(sessionId: String) -> String? {
        guard let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return nil }
        let rows = (try? db.query(
            "SELECT directory FROM session WHERE id = ?", [.text(sessionId)]) { $0.text(0) }) ?? []
        guard let cwd = rows.first ?? nil else { return nil }
        return projectResolver.projectName(forCwd: cwd)
    }
}
