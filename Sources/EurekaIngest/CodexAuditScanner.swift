import CryptoKit
import Foundation
import EurekaKit
import EurekaStore

/// Scans ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl and persists agent operations as an audit
/// log. Independent of CodexRolloutTailer: the tailer puts new files' offset at EOF (no history),
/// but audit needs completeness → it scans incrementally from a persisted offset (scan_files, keys
/// prefixed "audit://" to avoid clashing with the usage scanner). Covers every date directory in
/// the whole tree (resumed old sessions append in place in their creation-day dir); INSERT OR
/// IGNORE keeps rescans idempotent.
public final class CodexAuditScanner {
    private let sessionsRoot: URL
    private let store: EurekaStore
    private let pipeline: AuditPipeline
    private let staleThreshold: TimeInterval

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Per-file private scan state (stored in scan_files.extra): keeps session context across scan
    /// rounds
    private struct FileExtra: Codable {
        var sessionId: String?
        var cwd: String?
    }

    public init(
        sessionsRoot: URL, store: EurekaStore, pipeline: AuditPipeline,
        staleThreshold: TimeInterval = 300, lookbackDays: Int = 35
    ) {
        self.sessionsRoot = sessionsRoot
        self.store = store
        self.pipeline = pipeline
        self.staleThreshold = staleThreshold
        // lookbackDays is deprecated: enumeration is now a whole-tree recursion (resumed old
        // sessions append in place in their creation-day dir, so counting date dirs misses them);
        // the parameter is kept only for source compatibility. The scan_files watermark keeps
        // whole-tree rescans cheap.
        _ = lookbackDays
    }

    /// Scan every date directory in the whole tree once and return the number of audit rows newly
    /// inserted this round. alertSink receives high-risk alerts.
    @discardableResult
    public func scanOnce(alertSink: ((RiskAlert) -> Void)? = nil) throws -> Int {
        var inserted = 0
        for file in rolloutFiles() {
            inserted += try scanFile(file, alertSink: alertSink)
        }
        return inserted
    }

    private func rolloutFiles() -> [URL] {
        CodexRolloutFiles.enumerate(sessionsRoot: sessionsRoot).map(\.url)
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
                let payload = root["payload"] as? [String: Any] ?? [:]
                let timestamp = (root["timestamp"] as? String).flatMap {
                    Self.isoFormatter.date(from: $0)
                } ?? Date()

                if type == "session_meta" {
                    if let id = payload["id"] as? String { extra.sessionId = id }
                    if let cwd = payload["cwd"] as? String { extra.cwd = cwd }
                    continue
                }
                if type == "turn_context", let cwd = payload["cwd"] as? String {
                    extra.cwd = cwd
                    continue
                }
                guard let sessionId = extra.sessionId else { continue }
                let isStale = Date().timeIntervalSince(timestamp) > staleThreshold

                switch (type, payload["type"] as? String) {
                case ("response_item", "custom_tool_call"):
                    // **Current Codex's main command/patch channel** (surveyed the 12 largest
                    // rollouts: exec 1334 + apply_patch 97). It used to be unwired entirely → the
                    // audit log kept under-recording Codex's commands.
                    guard let name = payload["name"] as? String, !name.isEmpty else { continue }
                    let op = AuditExtractor.codexCustomTool(
                        name: name, input: payload["input"] as? String)
                    let callId = payload["call_id"] as? String
                    let event = AuditEvent(
                        opId: callId ?? Self.synthOpId(path: path, line: line),
                        source: .codex, sessionId: sessionId, timestamp: timestamp,
                        kind: op.kind, tool: op.name, detail: op.detail, cwd: extra.cwd)
                    let result = try pipeline.ingest(event, isStale: isStale)
                    if result.inserted { inserted += 1 }
                    if let alert = result.alert { alerts.append(alert) }

                case ("response_item", "custom_tool_call_output"):
                    guard let callId = payload["call_id"] as? String,
                          let outcome = AuditExtractor.codexOutcome(payload["output"])
                    else { continue }
                    try pipeline.markOutcome(
                        source: .codex, sessionId: sessionId, opId: callId,
                        exitCode: outcome.exitCode, isError: outcome.isError)

                case ("response_item", "function_call"):
                    // "_" prefix = MCP duplicate, skip (same rule as CodexUsageScanner; MCP goes
                    // through mcp_tool_call_end)
                    guard let name = payload["name"] as? String, !name.isEmpty, !name.hasPrefix("_")
                    else { continue }
                    let op = AuditExtractor.codex(
                        name: name, argumentsJSON: payload["arguments"] as? String)
                    let callId = payload["call_id"] as? String
                    let event = AuditEvent(
                        opId: callId ?? Self.synthOpId(path: path, line: line),
                        source: .codex, sessionId: sessionId, timestamp: timestamp,
                        kind: op.kind, tool: op.name, detail: op.detail, cwd: extra.cwd)
                    let result = try pipeline.ingest(event, isStale: isStale)
                    if result.inserted { inserted += 1 }
                    if let alert = result.alert { alerts.append(alert) }

                case ("response_item", "function_call_output"):
                    // Both formats are recognised: old rollouts' `metadata.exit_code` wins; the
                    // current version no longer has that field (0 occurrences of metadata in 2624
                    // surveyed entries) → fall back to the output-text heuristic.
                    guard let callId = payload["call_id"] as? String,
                          let outcome = AuditExtractor.codexOutcome(payload["output"])
                    else { continue }
                    try pipeline.markOutcome(
                        source: .codex, sessionId: sessionId, opId: callId,
                        exitCode: outcome.exitCode, isError: outcome.isError)

                case ("response_item", "web_search_call"):
                    let action = payload["action"] as? [String: Any]
                    let event = AuditEvent(
                        opId: Self.synthOpId(path: path, line: line),
                        source: .codex, sessionId: sessionId, timestamp: timestamp,
                        kind: .web, tool: "web_search",
                        detail: (action?["query"] as? String) ?? "", cwd: extra.cwd)
                    let result = try pipeline.ingest(event, isStale: isStale)
                    if result.inserted { inserted += 1 }
                    if let alert = result.alert { alerts.append(alert) }

                case ("event_msg", "mcp_tool_call_end"):
                    let inv = payload["invocation"] as? [String: Any] ?? [:]
                    let server = inv["server"] as? String ?? "mcp"
                    let tool = inv["tool"] as? String ?? "?"
                    let isError = (payload["result"] as? [String: Any])?["Err"] != nil
                    let detail = AuditExtractor.firstString(in: inv["arguments"] as? [String: Any])
                    let event = AuditEvent(
                        opId: Self.synthOpId(path: path, line: line),
                        source: .codex, sessionId: sessionId, timestamp: timestamp,
                        kind: .mcp, tool: "\(server).\(tool)", detail: detail,
                        cwd: extra.cwd, isError: isError)
                    let result = try pipeline.ingest(event, isStale: isStale)
                    if result.inserted { inserted += 1 }
                    if let alert = result.alert { alerts.append(alert) }

                default:
                    break
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

    /// Lines without a call_id (web_search / mcp) get a stable idempotency key synthesized as
    /// SHA256 of (path + line content). Rollout lines are immutable → stable across scans/rescans.
    private static func synthOpId(path: String, line: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(path.utf8))
        hasher.update(data: line)
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "synth:" + hex.prefix(32)
    }

    // MARK: - Incremental JSONL reading (EurekaUsage.JSONLinesReader isn't visible here; own copy)

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
