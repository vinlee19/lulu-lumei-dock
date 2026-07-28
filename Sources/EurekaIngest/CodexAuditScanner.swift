import CryptoKit
import Foundation
import EurekaKit
import EurekaStore

/// 扫描 ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl，把 agent 操作落成审计流水。
/// 独立于 CodexRolloutTailer：tailer 对新文件把 offset 置尾（不追历史），审计要完整性 →
/// 走持久化 offset 增量扫描（scan_files，键加 "audit://" 前缀避免与用量扫描器冲突）。
/// 整树覆盖全部日期目录（resume 的旧会话在创建日目录原地追加）；
/// INSERT OR IGNORE 保证重扫幂等。
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

    /// 每文件扫描私有状态（存 scan_files.extra）：跨扫描轮次保留会话上下文
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
        // lookbackDays 已废弃：枚举改为整树递归（resume 的旧会话在创建日目录原地追加，
        // 数日期目录会漏），保留形参仅为源码兼容；scan_files 水位线保证整树重扫廉价。
        _ = lookbackDays
    }

    /// 整树扫一遍所有日期目录，返回本轮新插入的审计行数。alertSink 接收高危告警。
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
                    // **当前 Codex 的命令/补丁主通道**（实勘 12 个最大 rollout：exec 1334 +
                    // apply_patch 97）。以前完全没接 → 审计流水一直在少记 Codex 的命令。
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
                    // "_" 前缀 = MCP 重复项，跳过（同 CodexUsageScanner 口径；MCP 走 mcp_tool_call_end）
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
                    // 两代格式都认：老 rollout 的 `metadata.exit_code` 优先，当前版本
                    // 已无该字段（实勘 2624 条里 metadata 出现 0 次）→ 退回输出文本判据。
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

    /// 无 call_id 的行（web_search / mcp）用 (路径+行内容) 的 SHA256 合成稳定幂等键。
    /// rollout 行不可变 → 跨扫描/重扫稳定。
    private static func synthOpId(path: String, line: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(path.utf8))
        hasher.update(data: line)
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "synth:" + hex.prefix(32)
    }

    // MARK: - JSONL 增量读取（EurekaUsage.JSONLinesReader 跨模块不可见，此处自带）

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
