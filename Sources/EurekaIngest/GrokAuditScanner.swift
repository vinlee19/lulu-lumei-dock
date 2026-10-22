import CryptoKit
import EurekaKit
import EurekaStore
import Foundation

/// Scans `~/.grok/sessions/<enc-cwd>/<uuid>/chat_history.jsonl` and records tool calls as audit
/// entries.
///
/// **Why chat_history instead of events.jsonl**: `tool_started` in `events.jsonl` only has
/// `tool_name` and **no arguments at all** (all 709 surveyed lines lack arguments). The audit
/// page's value is the full command / file path, and the risk rules (`RiskRuleEngine`) rely
/// entirely on `detail` — name-only lines would become a pile of empty records with no detail
/// that never match a risk rule, which is worse than nothing.
/// The lines that actually carry arguments are the `assistant` lines in `chat_history.jsonl`:
/// `tool_calls: [{id, name, arguments}]`, where `arguments` is a JSON string — the envelope
/// matches Codex's `function_call`, but **the vocabulary is Cursor's snake_case set**
/// (`read_file`/`target_file` rather than `exec_command`/`cmd`) → fed to `AuditExtractor.grok`,
/// which reuses Cursor's mapping internally and adds Grok-only `web_fetch`/`spawn_subagent`/
/// `use_tool` and the like.
///
/// Incremental scanning matches `CodexAuditScanner`: a persisted offset (`scan_files`, keys
/// prefixed `audit://` to stay clear of the usage scanners), and `INSERT OR IGNORE` keeps
/// rescans idempotent. The idempotency key is `tool_calls[].id` (surveyed as
/// `call-<uuid>-0`, stable and unique); when missing, a per-line hash is synthesized.
public final class GrokAuditScanner {
    private let sessionsRoot: URL
    private let store: EurekaStore
    /// The last slice read left more of the file unread (see `ScanSlices`)
    private var hasMoreSlices = false
    private let pipeline: AuditPipeline
    private let staleThreshold: TimeInterval

    /// Per-file private scan state (stored in scan_files.extra)
    private struct FileExtra: Codable {
        var sessionId: String?
        var cwd: String?
    }

    public init(
        sessionsRoot: URL, store: EurekaStore, pipeline: AuditPipeline,
        staleThreshold: TimeInterval = 300
    ) {
        self.sessionsRoot = sessionsRoot
        self.store = store
        self.pipeline = pipeline
        self.staleThreshold = staleThreshold
    }

    @discardableResult
    public func scanOnce(alertSink: ((RiskAlert) -> Void)? = nil) throws -> Int {
        var inserted = 0
        for file in historyFiles() {
            inserted += try ScanSlices.drain(
                stateKey: "audit://" + file.path, store: store, hasMore: { hasMoreSlices }
            ) {
                hasMoreSlices = false
                return try scanFile(file, alertSink: alertSink)
            }
        }
        return inserted
    }

    /// `sessions/<enc-cwd>/<uuid>/chat_history.jsonl` (two directory levels, not filtered by
    /// mtime — the scan_files watermark makes old files with no new data nearly free)
    private func historyFiles() -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let workspaceDirs = (try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for workspaceDir in workspaceDirs where isDirectory(workspaceDir) {
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: workspaceDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sessionDir in sessionDirs where isDirectory(sessionDir) {
                let file = sessionDir.appendingPathComponent("chat_history.jsonl")
                if fm.fileExists(atPath: file.path) { results.append(file) }
            }
        }
        return results
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func scanFile(_ url: URL, alertSink: ((RiskAlert) -> Void)?) throws -> Int {
        let path = url.path
        let auditKey = "audit://" + path
        guard let info = Self.fileInfo(path: path) else { return 0 }
        let saved = try store.scanState.fileState(path: auditKey)

        var offset: UInt64 = 0
        var extra = FileExtra()
        if let saved, saved.inode == info.inode, UInt64(saved.offset) <= info.size {
            offset = UInt64(saved.offset)
            if let json = saved.extra,
                let decoded = try? JSONDecoder().decode(FileExtra.self, from: Data(json.utf8)) {
                extra = decoded
            }
        }
        if extra.sessionId == nil { resolveOwnership(fileURL: url, into: &extra) }
        guard info.size > offset else { return 0 }
        guard let chunk = JSONLinesReader.read(path: path, from: offset) else { return 0 }
        hasMoreSlices = !chunk.reachedEnd

        var inserted = 0
        var alerts: [RiskAlert] = []
        try store.scanState.transaction {
            for line in chunk.lines {
                guard let object = try? JSONSerialization.jsonObject(with: line),
                    let root = object as? [String: Any],
                    root["type"] as? String == "assistant",
                    let calls = root["tool_calls"] as? [[String: Any]], !calls.isEmpty,
                    let sessionId = extra.sessionId
                else { continue }
                // chat_history lines carry no timestamp (the transcript page also fills it per turn
                // from events.jsonl), so the audit time falls back to the file mtime — closer to
                // when it really happened than Date()
                let timestamp = Self.mtime(path: path) ?? Date()
                let isStale = Date().timeIntervalSince(timestamp) > staleThreshold

                for call in calls {
                    guard let name = call["name"] as? String, !name.isEmpty else { continue }
                    let op = AuditExtractor.grok(
                        name: name, argumentsJSON: call["arguments"] as? String)
                    let event = AuditEvent(
                        opId: (call["id"] as? String)
                            ?? Self.synthOpId(path: path, line: line),
                        source: .grok, sessionId: sessionId, timestamp: timestamp,
                        kind: op.kind, tool: op.name, detail: op.detail, cwd: extra.cwd)
                    let result = try pipeline.ingest(event, isStale: isStale)
                    if result.inserted { inserted += 1 }
                    if let alert = result.alert { alerts.append(alert) }
                }
            }
            let extraJSON = String(
                data: (try? JSONEncoder().encode(extra)) ?? Data(), encoding: .utf8)
            try store.scanState.setFileState(
                path: auditKey,
                .init(inode: info.inode, offset: Int64(chunk.newOffset), extra: extraJSON))
        }
        alerts.forEach { alertSink?($0) }
        return inserted
    }

    /// Session ownership: the directory name is the session id; cwd comes from `summary.json`
    /// (the parent directory name is the **percent-encoded** cwd, but the encoding is lossy and
    /// differs across grok versions, so it is not decoded)
    private func resolveOwnership(fileURL: URL, into extra: inout FileExtra) {
        let sessionDir = fileURL.deletingLastPathComponent()
        extra.sessionId = sessionDir.lastPathComponent
        let summary = sessionDir.appendingPathComponent("summary.json")
        guard let data = try? Data(contentsOf: summary),
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        let info = root["info"] as? [String: Any]
        if let id = (info?["id"] as? String), !id.isEmpty { extra.sessionId = id }
        extra.cwd = (info?["cwd"] as? String) ?? (root["cwd"] as? String)
    }

    private static func synthOpId(path: String, line: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(path.utf8))
        hasher.update(data: line)
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "synth:" + hex.prefix(32)
    }

    private static func mtime(path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    // MARK: - File info (JSONL reading is the shared EurekaStore.JSONLinesReader)

    private static func fileInfo(path: String) -> (inode: Int64, size: UInt64)? {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (Int64(info.st_ino), UInt64(info.st_size))
    }
}
