import Foundation
import EurekaKit
import EurekaStore

/// Scans ~/.qwen/projects/<encoded>/chats/<uuid>.jsonl (observed in Qwen Code CLI v0.20).
/// Tokens live in `systemPayload.uiEvent` on type=system/subtype=ui_telemetry lines with
/// `event.name == "qwen-code.api_response"`: measured total = input + output (thoughts already
/// included in
/// output) → accounting: inputTokens = input − cached, cacheRead = cached, outputTokens = output
/// as-is.
/// dedup key = `qwen:<response_id>` (response_id is globally unique; guards against session-resume
/// rewrites and duplicate streamed lines).
/// User messages (non-empty body) count toward session_stats prompts.
public final class QwenUsageScanner {
    private let projectsRoot: URL
    private let store: EurekaStore
    /// The last slice read left more of the file unread (see `ScanSlices`)
    private var hasMoreSlices = false
    private let projectResolver = ProjectResolver()

    /// Per-file private state (stored in scan_files.extra): session/project attribution
    private struct FileExtra: Codable {
        var project: String?
        var sessionId: String?
    }

    /// Paths are passed in by the caller (app/CLI use QwenPaths, tests use a temp dir) -
    /// EurekaUsage doesn't depend on EurekaIngest, so there is no default here.
    public init(projectsRoot: URL, store: EurekaStore) {
        self.projectsRoot = projectsRoot
        self.store = store
    }

    /// Returns the number of usage records added this pass
    @discardableResult
    public func scanOnce() throws -> Int {
        var inserted = 0
        for file in chatFiles() {
            inserted += try ScanSlices.drain(
                stateKey: file.path, store: store, hasMore: { hasMoreSlices }
            ) {
                hasMoreSlices = false
                return try scanFile(file)
            }
        }
        return inserted
    }

    private func chatFiles() -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for projectDir in projectDirs
        where (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let chatsDir = projectDir.appendingPathComponent("chats", isDirectory: true)
            let files = (try? fm.contentsOfDirectory(
                at: chatsDir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension.lowercased() == "jsonl" {
                results.append(file)
            }
        }
        return results
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
            extra.sessionId = url.deletingPathExtension().lastPathComponent
        }
        guard info.size > offset else { return 0 }
        guard let chunk = JSONLinesReader.read(path: path, from: offset) else { return 0 }
        hasMoreSlices = !chunk.reachedEnd

        struct Candidate {
            var dedupKey: String
            var record: UsageRecord
        }
        var candidates: [Candidate] = []
        var promptCount = 0

        for line in chunk.lines {
            guard let object = try? JSONSerialization.jsonObject(with: line),
                  let root = object as? [String: Any]
            else { continue }
            if extra.project == nil, let cwd = root["cwd"] as? String {
                extra.project = projectResolver.projectName(forCwd: cwd)
            }
            let type = root["type"] as? String
            if type == "user",
               let message = root["message"] as? [String: Any],
               let parts = message["parts"] as? [[String: Any]],
               parts.contains(where: { ($0["text"] as? String)?.isEmpty == false }) {
                promptCount += 1
                continue
            }
            // ui_telemetry api_response event (tokens)
            guard type == "system",
                  root["subtype"] as? String == "ui_telemetry",
                  let payload = root["systemPayload"] as? [String: Any],
                  let event = payload["uiEvent"] as? [String: Any],
                  event["event.name"] as? String == "qwen-code.api_response",
                  let responseId = event["response_id"] as? String
            else { continue }
            let rawInput = (event["input_token_count"] as? NSNumber)?.intValue ?? 0
            let output = (event["output_token_count"] as? NSNumber)?.intValue ?? 0
            let cached = (event["cached_content_token_count"] as? NSNumber)?.intValue ?? 0
            guard rawInput > 0 || output > 0 else { continue }
            let timestamp = (event["event.timestamp"] as? String)
                .flatMap(Self.parseISO)
                ?? (root["timestamp"] as? String).flatMap(Self.parseISO)
                ?? Date()
            candidates.append(Candidate(
                dedupKey: "qwen:\(responseId)",
                record: UsageRecord(
                    source: .qwen,
                    model: (event["model"] as? String) ?? "qwen-unknown",
                    project: extra.project,
                    sessionId: extra.sessionId,
                    timestamp: timestamp,
                    inputTokens: max(0, rawInput - cached),
                    outputTokens: output,
                    cacheCreationTokens: 0,
                    cacheReadTokens: cached)))
        }

        var inserted = 0
        let extraJSON = String(
            data: (try? JSONEncoder().encode(extra)) ?? Data(), encoding: .utf8)
        try store.scanState.transaction {
            // Rewrites / streamed duplicates → filter via dedup_keys (including within-batch dedup)
            let existing = try store.scanState.existingDedupKeys(candidates.map(\.dedupKey))
            var seenThisBatch = Set<String>()
            for candidate in candidates
            where existing[candidate.dedupKey] == nil
                && seenThisBatch.insert(candidate.dedupKey).inserted {
                let recordId = try store.usage.insertReturningId(candidate.record)
                try store.scanState.upsertDedupKey(
                    candidate.dedupKey, recordId: recordId,
                    outputTokens: candidate.record.outputTokens,
                    at: candidate.record.timestamp)
                inserted += 1
            }
            try store.scanState.setFileState(
                path: path,
                .init(inode: info.inode, offset: Int64(chunk.newOffset), extra: extraJSON))
            if let sessionId = extra.sessionId {
                try store.sessionStats.recordPrompts(
                    path: path, sessionId: sessionId, count: promptCount, reset: offset == 0)
            }
        }
        return inserted
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func parseISO(_ string: String) -> Date? {
        isoWithFraction.date(from: string) ?? isoPlain.date(from: string)
    }
}
