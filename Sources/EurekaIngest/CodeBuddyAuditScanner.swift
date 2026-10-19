import CryptoKit
import Foundation
import EurekaKit
import EurekaStore

/// Scans ~/.codebuddy/projects/**/*.jsonl (including `<sessionId>/subagents/agent-*.jsonl`) and
/// turns function_call tool calls into audit records. Schema verified against real sessions
/// (2026-07): `type:"function_call"` lines carry `name` + `arguments` (a JSON string) + `callId` +
/// `timestamp` (epoch milliseconds) + `cwd`.
/// Same shape as CodexAuditScanner: incremental scan from a persisted offset (scan_files, keys
/// prefixed with "audit://" to avoid colliding with the usage scanner); INSERT OR IGNORE keeps
/// rescans idempotent.
/// Two conventions that differ from codex:
/// - The tool vocabulary is Claude-style (Read/Grep/Glob/Bash/Write/Agent...; none of 530 observed
///   function_call lines used a codex-style name) → arguments are parsed into a dictionary and fed
///   to `AuditExtractor.claude(name:input:)`; fed to the codex extractor, everything would land in
///   default (kind=.other) and the risk rules would never fire.
/// - The sessionId inside subagent lines is the subagent's own id (observed), so attribution to the
///   parent session must be derived from the path (the parent directory name of
///   `<slug>/<sessionId>/subagents/`), same convention as CodeBuddyUsageScanner.
public final class CodeBuddyAuditScanner {
    private let projectsRoot: URL
    private let store: EurekaStore
    private let pipeline: AuditPipeline
    private let staleThreshold: TimeInterval

    /// Private per-file scan state (stored in scan_files.extra): path-derived session attribution +
    /// cached inline cwd
    private struct FileExtra: Codable {
        var sessionId: String?
        var cwd: String?
    }

    public init(
        projectsRoot: URL, store: EurekaStore, pipeline: AuditPipeline,
        staleThreshold: TimeInterval = 300
    ) {
        self.projectsRoot = projectsRoot
        self.store = store
        self.pipeline = pipeline
        self.staleThreshold = staleThreshold
    }

    /// Scans the whole tree once (including subagents/) and returns the number of audit rows newly
    /// inserted this pass. alertSink receives high-risk alerts.
    @discardableResult
    public func scanOnce(alertSink: ((RiskAlert) -> Void)? = nil) throws -> Int {
        var inserted = 0
        for file in sessionFiles() {
            inserted += try scanFile(file, alertSink: alertSink)
        }
        return inserted
    }

    /// projects/<slug>/*.jsonl (main sessions) + projects/<slug>/<sessionId>/subagents/*.jsonl
    /// (subagents; not filtered by mtime, since the scan_state watermark makes old files with no
    /// new data nearly free). Same enumeration convention as CodeBuddyUsageScanner.sessionFiles().
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

    private func scanFile(_ url: URL, alertSink: ((RiskAlert) -> Void)?) throws -> Int {
        let path = url.path
        let auditKey = "audit://" + path
        guard let info = Self.fileInfo(path: path) else { return 0 }
        let saved = try store.scanState.fileState(path: auditKey)

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
        guard let chunk = Self.read(path: path, from: offset) else { return 0 }

        var inserted = 0
        var alerts: [RiskAlert] = []
        try store.scanState.transaction {
            for line in chunk.lines {
                guard
                    let object = try? JSONSerialization.jsonObject(with: line),
                    let root = object as? [String: Any],
                    root["type"] as? String == "function_call",
                    let name = root["name"] as? String, !name.isEmpty,
                    let sessionId = extra.sessionId
                else { continue }
                if let cwd = root["cwd"] as? String { extra.cwd = cwd }
                let timestamp = CodeBuddyTranscriptDecoder.timestamp(root) ?? Date()
                let isStale = Date().timeIntervalSince(timestamp) > staleThreshold

                // arguments is a JSON string (true for 530/530 observed lines); a parse failure
                // falls back to an empty dictionary
                var args: [String: Any] = [:]
                if let raw = root["arguments"] as? String,
                   let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) {
                    args = parsed as? [String: Any] ?? [:]
                }
                let op = AuditExtractor.claude(name: name, input: args)
                let event = AuditEvent(
                    opId: (root["callId"] as? String) ?? Self.synthOpId(path: path, line: line),
                    source: .codebuddy, sessionId: sessionId, timestamp: timestamp,
                    kind: op.kind, tool: op.name, detail: op.detail, cwd: extra.cwd)
                let result = try pipeline.ingest(event, isStale: isStale)
                if result.inserted { inserted += 1 }
                if let alert = result.alert { alerts.append(alert) }
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

    /// Session attribution: a main session file = <slug>/<sessionId>.jsonl (the file stem is the
    /// session id); a subagent file = <slug>/<sessionId>/subagents/agent-*.jsonl (the parent
    /// directory name is the parent session id; the inline sessionId is the subagent's own and is
    /// not used). Same convention as CodeBuddyUsageScanner.
    private func resolveOwnership(fileURL: URL, into extra: inout FileExtra) {
        let parent = fileURL.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" {
            extra.sessionId = parent.deletingLastPathComponent().lastPathComponent
        } else {
            extra.sessionId = fileURL.deletingPathExtension().lastPathComponent
        }
    }

    /// Lines without a callId get a stable idempotency key synthesized from the SHA256 of (path +
    /// line content), same as CodexAuditScanner.
    private static func synthOpId(path: String, line: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(path.utf8))
        hasher.update(data: line)
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "synth:" + hex.prefix(32)
    }

    // MARK: - Incremental JSONL reading (own copy: EurekaUsage.JSONLinesReader is module-internal)

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
