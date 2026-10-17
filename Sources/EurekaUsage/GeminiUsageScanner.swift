import Foundation
import EurekaKit
import EurekaStore

/// Scans ~/.gemini/tmp/<slug>/chats/session-*.jsonl (format observed in Gemini CLI v0.51).
/// Message lines with `type == "gemini"` carry model and tokens{input, output, cached, thoughts}:
/// Gemini's input includes cached, and thoughts bill as output → stored as
/// inputTokens = input - cached, cacheRead = cached, outputTokens = output + thoughts.
/// `type == "user"` lines (not session_context injections) count toward session_stats prompts.
/// Reads incrementally from an inode+offset watermark; resuming a session may rewrite the whole
/// file (watermark invalidated → reread from 0),
/// so usage records also go through dedup_keys (gemini:<sessionId>:<messageId>) as a fallback.
public final class GeminiUsageScanner {
    private let tmpRoot: URL
    private let projectsFile: URL
    private let store: EurekaStore
    private let projectResolver = ProjectResolver()

    /// Per-file private state (stored in scan_files.extra): session/project attribution (parsed
    /// from header/slug on first scan)
    private struct FileExtra: Codable {
        var project: String?
        var sessionId: String?
    }

    /// Paths are passed in by the caller (app/CLI use GeminiPaths, tests use a temp dir) -
    /// EurekaUsage doesn't depend on EurekaIngest, so there is no default here.
    public init(tmpRoot: URL, projectsFile: URL, store: EurekaStore) {
        self.tmpRoot = tmpRoot
        self.projectsFile = projectsFile
        self.store = store
    }

    /// Returns the number of usage records added this pass
    @discardableResult
    public func scanOnce() throws -> Int {
        let slugToProject = loadSlugMap()
        var inserted = 0
        for (file, slug) in chatFiles() {
            inserted += try scanFile(file, cwd: slugToProject[slug])
        }
        return inserted
    }

    /// {"projects": {"/abs/path": "slug"}} → slug: path
    private func loadSlugMap() -> [String: String] {
        guard let data = try? Data(contentsOf: projectsFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [String: String]
        else { return [:] }
        var reversed: [String: String] = [:]
        for (path, slug) in projects { reversed[slug] = path }
        return reversed
    }

    private func chatFiles() -> [(URL, String)] {
        let fm = FileManager.default
        var results: [(URL, String)] = []
        let slugDirs = (try? fm.contentsOfDirectory(
            at: tmpRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for slugDir in slugDirs
        where (try? slugDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let chatsDir = slugDir.appendingPathComponent("chats", isDirectory: true)
            let files = (try? fm.contentsOfDirectory(
                at: chatsDir, includingPropertiesForKeys: nil)) ?? []
            for file in files
            where file.lastPathComponent.hasPrefix("session-")
                && file.pathExtension.lowercased() == "jsonl" {
                results.append((file, slugDir.lastPathComponent))
            }
        }
        return results
    }

    private func scanFile(_ url: URL, cwd: String?) throws -> Int {
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
        if extra.project == nil, let cwd {
            extra.project = projectResolver.projectName(forCwd: cwd)
        }
        guard info.size > offset else { return 0 }
        guard let chunk = JSONLinesReader.read(path: path, from: offset) else { return 0 }

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
            // header line (sessionId attribution)
            if extra.sessionId == nil, let sessionId = root["sessionId"] as? String,
               root["type"] == nil {
                extra.sessionId = sessionId
                continue
            }
            guard root["$set"] == nil, let type = root["type"] as? String else { continue }

            if type == "user" {
                let text = Self.contentText(root["content"])
                if !text.hasPrefix("<session_context>") { promptCount += 1 }
                continue
            }
            guard type == "gemini", let usage = root["tokens"] as? [String: Any] else { continue }
            let rawInput = (usage["input"] as? NSNumber)?.intValue ?? 0
            let output = (usage["output"] as? NSNumber)?.intValue ?? 0
            let cached = (usage["cached"] as? NSNumber)?.intValue ?? 0
            let thoughts = (usage["thoughts"] as? NSNumber)?.intValue ?? 0
            guard rawInput > 0 || output > 0 || thoughts > 0 else { continue }
            let messageId = (root["id"] as? String) ?? UUID().uuidString
            let timestamp = (root["timestamp"] as? String)
                .flatMap(Self.parseISO) ?? Date()
            candidates.append(Candidate(
                dedupKey: "gemini:\(extra.sessionId ?? path):\(messageId)",
                record: UsageRecord(
                    source: .gemini,
                    model: (root["model"] as? String) ?? "gemini-unknown",
                    project: extra.project,
                    sessionId: extra.sessionId,
                    timestamp: timestamp,
                    inputTokens: max(0, rawInput - cached),
                    outputTokens: output + thoughts,
                    cacheCreationTokens: 0,
                    cacheReadTokens: cached)))
        }

        var inserted = 0
        let extraJSON = String(
            data: (try? JSONEncoder().encode(extra)) ?? Data(), encoding: .utf8)
        try store.scanState.transaction {
            // Resuming a session may rewrite the whole file → filter already-seen messages via
            // dedup_keys; CLI streaming writes the same message line twice → also dedup within the
            // batch (seenThisBatch)
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

    private static func contentText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
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
