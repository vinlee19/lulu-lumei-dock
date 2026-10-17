import CryptoKit
import Foundation
import EurekaKit
import EurekaStore

/// Scans ~/.qoder-cn/projects/**/*.jsonl (including `<sessionId>/subagents/agent-*.jsonl`) and
/// records tool_use blocks in assistant messages as audit entries. Schema verified against real
/// sessions (v1.1.5, 2026-07): a Claude-style envelope, where `message.content[]` on
/// `type:"assistant"` lines contains `{"type":"tool_use","id":…,"name":…,"input":{…}}`;
/// `timestamp` is an ISO-8601 string (meta lines such as runtime-config use epoch ms and are
/// not audited); `cwd` is a line field (fallback: directories[0] of the first
/// workspace-directories line).
/// Same shape as CodexAuditScanner: incremental scanning with a persisted offset (scan_files,
/// keys prefixed "audit://" to avoid colliding with the usage scanners), and INSERT OR IGNORE
/// keeps rescans idempotent.
/// The tool vocabulary is Claude-style (Read/Bash/Grep/Glob/Agent…) → fed straight to
/// `AuditExtractor.claude(name:input:)`. Subagent files are attributed to the parent session id
/// by path (the parent directory name of `<slug>/<sessionId>/subagents/`), same convention as
/// the CodeBuddy scanner.
public final class QoderAuditScanner {
    private let projectsRoot: URL
    private let store: EurekaStore
    private let pipeline: AuditPipeline
    private let staleThreshold: TimeInterval

    /// Per-file private scan state (stored in scan_files.extra): path-derived session ownership +
    /// cached line cwd
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

    /// Scans the whole tree once (including subagents/); returns the number of audit rows newly
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
    /// (subagents; not filtered by mtime — the scan_state watermark makes old files with no new
    /// data nearly free). Same enumeration as CodeBuddyAuditScanner.sessionFiles() (identical
    /// layout).
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
                    let type = root["type"] as? String
                else { continue }
                if let cwd = QoderTranscriptDecoder.cwd(root) { extra.cwd = cwd }
                // Only collect tool_use blocks from assistant lines; skip other types fast
                guard type == "assistant",
                      let message = root["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]],
                      let sessionId = extra.sessionId
                else { continue }
                let timestamp = QoderTranscriptDecoder.timestamp(root) ?? Date()
                let isStale = Date().timeIntervalSince(timestamp) > staleThreshold

                var toolUseIndex = 0
                for block in blocks where block["type"] as? String == "tool_use" {
                    defer { toolUseIndex += 1 }
                    guard let name = block["name"] as? String, !name.isEmpty else { continue }
                    let op = AuditExtractor.claude(name: name, input: block["input"] as? [String: Any])
                    let event = AuditEvent(
                        opId: (block["id"] as? String)
                            ?? Self.synthOpId(path: path, line: line, index: toolUseIndex),
                        source: .qoder, sessionId: sessionId, timestamp: timestamp,
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

    /// Session ownership: main session file = <slug>/<sessionId>.jsonl (the file name stem is the
    /// session id); subagent file = <slug>/<sessionId>/subagents/agent-*.jsonl (the parent
    /// directory name is the parent session id).
    private func resolveOwnership(fileURL: URL, into extra: inout FileExtra) {
        let parent = fileURL.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" {
            extra.sessionId = parent.deletingLastPathComponent().lastPathComponent
        } else {
            extra.sessionId = fileURL.deletingPathExtension().lastPathComponent
        }
    }

    /// tool_use blocks without an id get a stable idempotency key from SHA256(path + line content
    /// + block index) (one line may hold several tool_use blocks; the index disambiguates).
    private static func synthOpId(path: String, line: Data, index: Int) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(path.utf8))
        hasher.update(data: line)
        hasher.update(data: Data([UInt8(index)]))
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "synth:" + hex.prefix(32)
    }

    // MARK: - Incremental JSONL reading (EurekaUsage.JSONLinesReader is not visible across modules, so this carries its own)

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
