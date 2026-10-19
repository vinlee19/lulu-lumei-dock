import CryptoKit
import EurekaKit
import EurekaStore
import Foundation

/// Scans `~/.qwen/projects/<slug>/chats/<uuid>.jsonl` and persists each `functionCall` as an audit
/// record.
///
/// Lines use a hybrid Claude-style envelope with every needed field on the line (surveyed v0.2, 2026-07):
/// `{type:"assistant", sessionId, cwd, timestamp, message:{parts:[{functionCall:{id,name,args}}]}}`.
/// Unlike Codex/Grok, `args` is already a **structured object**, not a JSON string.
///
/// The vocabulary is the same snake_case set as Cursor/Grok (observed `read_file`(file_path) / `grep_search`(pattern,path) /
/// `agent`(subagent_type) / `ask_user_question`), so it reuses `AuditExtractor.qwen`, which goes through
/// the shared snake_case mapping. Local Qwen usage is very light (only 4 tools, 28 calls seen),
/// so the vocabulary is **not exhaustive**; unrecognized names land as `.other` + first string arg, no row is dropped.
///
/// Incremental like the other audit scanners: `scan_files` persists the offset (key prefixed with `audit://`),
/// and `INSERT OR IGNORE` keeps rescans idempotent; the idempotency key is `functionCall.id`, or a per-line hash when absent.
public final class QwenAuditScanner {
    private let projectsRoot: URL
    private let store: EurekaStore
    private let pipeline: AuditPipeline
    private let staleThreshold: TimeInterval

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(
        projectsRoot: URL, store: EurekaStore, pipeline: AuditPipeline,
        staleThreshold: TimeInterval = 300
    ) {
        self.projectsRoot = projectsRoot
        self.store = store
        self.pipeline = pipeline
        self.staleThreshold = staleThreshold
    }

    @discardableResult
    public func scanOnce(alertSink: ((RiskAlert) -> Void)? = nil) throws -> Int {
        var inserted = 0
        for file in chatFiles() {
            inserted += try scanFile(file, alertSink: alertSink)
        }
        return inserted
    }

    /// `projects/<slug>/chats/*.jsonl` (no mtime filter: the scan_files watermark makes old files
    /// nearly free)
    private func chatFiles() -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for projectDir in projectDirs {
            let chats = projectDir.appendingPathComponent("chats", isDirectory: true)
            let files = (try? fm.contentsOfDirectory(at: chats, includingPropertiesForKeys: nil))
                ?? []
            results += files.filter { $0.pathExtension.lowercased() == "jsonl" }
        }
        return results
    }

    private func scanFile(_ url: URL, alertSink: ((RiskAlert) -> Void)?) throws -> Int {
        let path = url.path
        let auditKey = "audit://" + path
        guard let info = Self.fileInfo(path: path) else { return 0 }
        let saved = try store.scanState.fileState(path: auditKey)

        var offset: UInt64 = 0
        if let saved, saved.inode == info.inode, UInt64(saved.offset) <= info.size {
            offset = UInt64(saved.offset)
        }
        guard info.size > offset else { return 0 }
        guard let chunk = Self.read(path: path, from: offset) else { return 0 }
        // Session id fallback: the file name stem (lines usually carry sessionId themselves)
        let fallbackSessionId = url.deletingPathExtension().lastPathComponent

        var inserted = 0
        var alerts: [RiskAlert] = []
        try store.scanState.transaction {
            for line in chunk.lines {
                guard let object = try? JSONSerialization.jsonObject(with: line),
                    let root = object as? [String: Any],
                    let parts = (root["message"] as? [String: Any])?["parts"] as? [[String: Any]]
                else { continue }
                let sessionId = (root["sessionId"] as? String).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? fallbackSessionId
                let cwd = (root["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let timestamp = (root["timestamp"] as? String)
                    .flatMap { Self.isoFormatter.date(from: $0) } ?? Date()
                let isStale = Date().timeIntervalSince(timestamp) > staleThreshold

                for part in parts {
                    guard let call = part["functionCall"] as? [String: Any],
                        let name = call["name"] as? String, !name.isEmpty
                    else { continue }
                    let op = AuditExtractor.qwen(
                        name: name, args: call["args"] as? [String: Any])
                    let event = AuditEvent(
                        opId: (call["id"] as? String)
                            ?? Self.synthOpId(path: path, line: line),
                        source: .qwen, sessionId: sessionId, timestamp: timestamp,
                        kind: op.kind, tool: op.name, detail: op.detail, cwd: cwd)
                    let result = try pipeline.ingest(event, isStale: isStale)
                    if result.inserted { inserted += 1 }
                    if let alert = result.alert { alerts.append(alert) }
                }
            }
            try store.scanState.setFileState(
                path: auditKey,
                .init(inode: info.inode, offset: Int64(chunk.newOffset), extra: nil))
        }
        alerts.forEach { alertSink?($0) }
        return inserted
    }

    private static func synthOpId(path: String, line: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(path.utf8))
        hasher.update(data: line)
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "synth:" + hex.prefix(32)
    }

    // MARK: - Incremental JSONL reading (EurekaUsage.JSONLinesReader isn't visible across modules, so we carry our own)

    private struct Chunk {
        var lines: [Data]
        var newOffset: UInt64
    }

    private static func read(path: String, from offset: UInt64) -> Chunk? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
            let data = try? handle.readToEnd(), !data.isEmpty
        else { return nil }
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return nil }
        let complete = data[data.startIndex...lastNewline]
        let lines = complete
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { Data($0) }
        return Chunk(lines: lines, newOffset: offset + UInt64(complete.count))
    }

    private static func fileInfo(path: String) -> (inode: Int64, size: UInt64)? {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (Int64(info.st_ino), UInt64(info.st_size))
    }
}
