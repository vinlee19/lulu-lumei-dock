import Foundation
import EurekaKit
import EurekaStore

/// Scans two files under ~/.grok/sessions/<enc-cwd>/<uuid>/:
/// - `events.jsonl`: `tool_started` (tool calls → tool_calls) and `turn_started` (prompts →
///   session_stats);
/// - `updates.jsonl`: the end-of-turn `turn_completed` (since Grok 1.0.4x), whose
///   `usage.modelUsage.<model>` carries that turn's tokens and `costUsdTicks` (10¹⁰ ticks = 1 USD,
///   Grok's self-reported API-equivalent cost) → one usage_records row per turn per model, using
///   the self-reported cost directly (build models have no price catalog entry).
/// Each file is read incrementally from its own inode+offset watermark (same shape as the
/// Codex/opencode scanners).
public final class GrokUsageScanner {
    private let sessionsRoot: URL
    private let store: EurekaStore
    /// The last slice read left more of the file unread (see `ScanSlices`)
    private var hasMoreSlices = false

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Per-file private state (stored in scan_files.extra): session id (consistent with
    /// GrokSessionIndexer)
    private struct FileExtra: Codable {
        var sessionId: String?
    }

    /// sessionsRoot is passed in by the caller (app/CLI use `GrokPaths.sessionsRoot()`, tests use a
    /// temp dir) — EurekaUsage does not depend on EurekaIngest, so there is no default here.
    public init(sessionsRoot: URL, store: EurekaStore) {
        self.sessionsRoot = sessionsRoot
        self.store = store
    }

    private let projectResolver = ProjectResolver()
    private static let turnCompletedMarker = Data("\"turn_completed\"".utf8)

    /// Returns the tool-call count + usage record count added this pass
    @discardableResult
    public func scanOnce() throws -> Int {
        var bumped = 0
        for file in eventFiles() {
            bumped += try ScanSlices.drain(
                path: file.path, store: store, hasMore: { hasMoreSlices }
            ) {
                hasMoreSlices = false
                return try scanFile(file)
            }
            let updates = file.deletingLastPathComponent().appendingPathComponent("updates.jsonl")
            if FileManager.default.fileExists(atPath: updates.path) {
                bumped += try ScanSlices.drain(
                path: updates.path, store: store, hasMore: { hasMoreSlices }
            ) {
                hasMoreSlices = false
                return try scanUpdates(updates)
            }
            }
        }
        return bumped
    }

    /// turn_completed in updates.jsonl → usage_records. A rewritten file (new inode / shorter) is
    /// rescanned from the start: delete the session's booked rows first, then rewrite; never rely
    /// on dedup keys, which are pruned after 8 days.
    private func scanUpdates(_ url: URL) throws -> Int {
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

        let sessionDir = url.deletingLastPathComponent()
        let sessionId = resolveSessionId(sessionDir: sessionDir)
        // The parent dir name is the percent-encoded cwd (%2FUsers%2F…)
        let cwd = sessionDir.deletingLastPathComponent().lastPathComponent.removingPercentEncoding
        let project = projectResolver.projectName(forCwd: cwd)

        var records: [UsageRecord] = []
        for line in chunk.lines {
            // Most of the file is streamed body text (up to 76MB seen), so filter on bytes before
            // parsing
            guard line.range(of: Self.turnCompletedMarker) != nil,
                let object = try? JSONSerialization.jsonObject(with: line),
                let root = object as? [String: Any],
                let params = root["params"] as? [String: Any],
                let update = params["update"] as? [String: Any],
                update["sessionUpdate"] as? String == "turn_completed",
                let usage = update["usage"] as? [String: Any]
            else { continue }
            let meta = params["_meta"] as? [String: Any]
            let timestamp = ((meta?["agentTimestampMs"] as? NSNumber)?.doubleValue).map {
                Date(timeIntervalSince1970: $0 / 1000)
            } ?? ((root["timestamp"] as? NSNumber)?.doubleValue).map(Date.init(timeIntervalSince1970:))
                ?? Date()
            // Split by model; older versions without modelUsage book the whole turn under
            // primaryModel / grok
            var perModel = usage["modelUsage"] as? [String: [String: Any]] ?? [:]
            if perModel.isEmpty { perModel = ["grok": usage] }
            for (model, counts) in perModel {
                func int(_ key: String) -> Int { (counts[key] as? NSNumber)?.intValue ?? 0 }
                let input = int("inputTokens")
                let cachedRead = int("cachedReadTokens")
                let output = int("outputTokens")
                let cacheWrite = int("cacheCreationTokens")
                guard input > 0 || output > 0 || cacheWrite > 0 else { continue }
                let ticks = (counts["costUsdTicks"] as? NSNumber)?.doubleValue
                records.append(UsageRecord(
                    source: .grok,
                    model: model,
                    project: project,
                    sessionId: sessionId,
                    timestamp: timestamp,
                    // inputTokens includes cache reads (OpenAI convention) → split them out;
                    // reasoning is already in outputTokens
                    inputTokens: max(0, input - cachedRead),
                    outputTokens: output,
                    cacheCreationTokens: cacheWrite,
                    cacheReadTokens: cachedRead,
                    provider: "xai",
                    reportedCostUSD: ticks.map { $0 / 1e10 }))
            }
        }

        try store.scanState.transaction {
            if offset == 0 { try store.usage.deleteRecords(source: .grok, sessionId: sessionId) }
            try store.usage.insert(records)
            try store.scanState.setFileState(
                path: path, .init(inode: info.inode, offset: Int64(chunk.newOffset)))
        }
        return records.count
    }

    /// All of sessions/<enc-cwd>/<uuid>/events.jsonl (two-level directory walk; no mtime filter —
    /// the scan_state watermark makes old files with no new data nearly free, and each line is
    /// bucketed by its own `ts`, so historic activity lands on historic dates without affecting
    /// this month).
    private func eventFiles() -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let cwdDirs = (try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for cwdDir in cwdDirs where isDirectory(cwdDir) {
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: cwdDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sessionDir in sessionDirs where isDirectory(sessionDir) {
                let events = sessionDir.appendingPathComponent("events.jsonl")
                if fm.fileExists(atPath: events.path) { results.append(events) }
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
        // Session id: consistent with GrokSessionIndexer (summary.json info.id, else the dir name),
        // so session_stats rows can join to the session list by id
        if extra.sessionId == nil {
            extra.sessionId = resolveSessionId(sessionDir: url.deletingLastPathComponent())
        }
        guard info.size > offset else { return 0 }
        guard let chunk = JSONLinesReader.read(path: path, from: offset) else { return 0 }
        hasMoreSlices = !chunk.reachedEnd

        var promptCount = 0
        var toolBumps: [String: Int] = [:]  // "day\u{1}name" → count
        for line in chunk.lines {
            guard
                let object = try? JSONSerialization.jsonObject(with: line),
                let root = object as? [String: Any],
                let type = root["type"] as? String
            else { continue }
            switch type {
            case "turn_started":
                promptCount += 1
            case "tool_started":
                guard let name = root["tool_name"] as? String, !name.isEmpty else { continue }
                let day = (root["ts"] as? String).flatMap { Self.isoFormatter.date(from: $0) }
                    .map { Self.dayFormatter.string(from: $0) }
                    ?? Self.dayFormatter.string(from: Date())
                toolBumps["\(day)\u{1}\(name)", default: 0] += 1
            default:
                break
            }
        }

        var bumped = 0
        let extraJSON = String(
            data: (try? JSONEncoder().encode(extra)) ?? Data(), encoding: .utf8)
        try store.scanState.transaction {
            for (composite, count) in toolBumps {
                let parts = composite.components(separatedBy: "\u{1}")
                guard parts.count == 2 else { continue }
                try store.toolCalls.bump(
                    day: parts[0], source: .grok, kind: "tool", name: parts[1], by: count)
                bumped += count
            }
            try store.scanState.setFileState(
                path: path,
                .init(inode: info.inode, offset: Int64(chunk.newOffset), extra: extraJSON))
            if let sessionId = extra.sessionId {
                try store.sessionStats.recordPrompts(
                    path: path, sessionId: sessionId, count: promptCount, reset: offset == 0)
            }
        }
        return bumped
    }

    /// Same as GrokSessionIndexer: summary.json's info.id, else the session dir name
    private func resolveSessionId(sessionDir: URL) -> String {
        let summary = sessionDir.appendingPathComponent("summary.json")
        if let data = try? Data(contentsOf: summary),
           let object = try? JSONSerialization.jsonObject(with: data),
           let root = object as? [String: Any],
           let info = root["info"] as? [String: Any],
           let id = info["id"] as? String, !id.isEmpty {
            return id
        }
        return sessionDir.lastPathComponent
    }
}
