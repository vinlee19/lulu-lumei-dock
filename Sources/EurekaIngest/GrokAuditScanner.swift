import CryptoKit
import EurekaKit
import EurekaStore
import Foundation

/// 扫描 `~/.grok/sessions/<enc-cwd>/<uuid>/chat_history.jsonl`，把工具调用落成审计流水。
///
/// **为什么读 chat_history 而不是 events.jsonl**：`events.jsonl` 里的 `tool_started`
/// 只有 `tool_name`，**没有任何参数**（实勘 709 条全无 arguments）。审计页的价值在完整
/// 命令 / 文件路径，风险规则（`RiskRuleEngine`）也全靠 `detail` 判定 —— 只有名字的行
/// 落进去就是一堆没有 detail、永不命中风险规则的空记录，比不做更糟。
/// 真正带参数的是 `chat_history.jsonl` 的 `assistant` 行：
/// `tool_calls: [{id, name, arguments}]`，`arguments` 是 JSON 字符串 ——
/// 信封与 Codex 的 `function_call` 同形，但**词表是 Cursor 那套 snake_case**
/// （`read_file`/`target_file` 而非 `exec_command`/`cmd`）→ 喂 `AuditExtractor.grok`，
/// 它内部复用 Cursor 的映射并补上 Grok 独有的 `web_fetch`/`spawn_subagent`/`use_tool` 等。
///
/// 增量方式与 `CodexAuditScanner` 一致：持久化 offset（`scan_files`，键带 `audit://`
/// 前缀避开用量扫描器），`INSERT OR IGNORE` 保证重扫幂等。
/// 幂等键取 `tool_calls[].id`（实勘形如 `call-<uuid>-0`，稳定唯一）；缺失时按行合成 hash。
public final class GrokAuditScanner {
    private let sessionsRoot: URL
    private let store: EurekaStore
    private let pipeline: AuditPipeline
    private let staleThreshold: TimeInterval

    /// 每文件扫描私有状态（存 scan_files.extra）
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
            inserted += try scanFile(file, alertSink: alertSink)
        }
        return inserted
    }

    /// `sessions/<enc-cwd>/<uuid>/chat_history.jsonl`（两级目录，不按 mtime 过滤 ——
    /// scan_files 水位让无新数据的老文件近乎零成本）
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
        guard let chunk = Self.read(path: path, from: offset) else { return 0 }

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
                // chat_history 行不带时间戳（转录页也是按轮次从 events.jsonl 补的），
                // 审计时间退文件 mtime——比记 Date() 更接近真实发生时刻
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

    /// 会话归属：目录名即 session id；cwd 从 `summary.json` 取（父目录名是**百分号编码**
    /// 的 cwd，但编码有损且不同 grok 版本不一致，不反解）
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
