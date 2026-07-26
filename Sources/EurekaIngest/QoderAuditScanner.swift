import CryptoKit
import Foundation
import EurekaKit
import EurekaStore

/// 扫描 ~/.qoder-cn/projects/**/*.jsonl（含 `<sessionId>/subagents/agent-*.jsonl`），
/// 把 assistant 消息里的 tool_use 块落成审计流水。schema 已对真实会话核验
/// （v1.1.5，2026-07）：Claude 式信封，`type:"assistant"` 行的
/// `message.content[]` 内含 `{"type":"tool_use","id":…,"name":…,"input":{…}}`；
/// `timestamp` 是 ISO-8601 字符串（runtime-config 等元行是 epoch 毫秒，不进审计）；
/// `cwd` 在行字段（首行 workspace-directories 的 directories[0] 兜底）。
/// 与 CodexAuditScanner 同构：持久化 offset 增量扫描（scan_files，键加 "audit://"
/// 前缀避免与用量扫描器冲突），INSERT OR IGNORE 保证重扫幂等。
/// 工具词汇是 Claude 式（Read/Bash/Grep/Glob/Agent…）→ 直接喂
/// `AuditExtractor.claude(name:input:)`。子代理文件按路径归属父会话 id
/// （`<slug>/<sessionId>/subagents/` 的父目录名），与 CodeBuddy 扫描器同口径。
public final class QoderAuditScanner {
    private let projectsRoot: URL
    private let store: EurekaStore
    private let pipeline: AuditPipeline
    private let staleThreshold: TimeInterval

    /// 每文件扫描私有状态（存 scan_files.extra）：路径推导的会话归属 + 行内 cwd 缓存
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

    /// 整树扫一遍（含 subagents/），返回本轮新插入的审计行数。alertSink 接收高危告警。
    @discardableResult
    public func scanOnce(alertSink: ((RiskAlert) -> Void)? = nil) throws -> Int {
        var inserted = 0
        for file in sessionFiles() {
            inserted += try scanFile(file, alertSink: alertSink)
        }
        return inserted
    }

    /// projects/<slug>/*.jsonl（主会话）+ projects/<slug>/<sessionId>/subagents/*.jsonl
    /// （子代理；不按 mtime 过滤——scan_state 水位使无新数据的老文件近乎零成本）。
    /// 与 CodeBuddyAuditScanner.sessionFiles() 同一枚举口径（布局相同）。
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
                // 只收 assistant 行的 tool_use 块，其余类型快速跳过
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

    /// 会话归属：主会话文件 = <slug>/<sessionId>.jsonl（文件名 stem 即会话 id）；
    /// 子代理文件 = <slug>/<sessionId>/subagents/agent-*.jsonl（父目录名即父会话 id）。
    private func resolveOwnership(fileURL: URL, into extra: inout FileExtra) {
        let parent = fileURL.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" {
            extra.sessionId = parent.deletingLastPathComponent().lastPathComponent
        } else {
            extra.sessionId = fileURL.deletingPathExtension().lastPathComponent
        }
    }

    /// 无 id 的 tool_use 块用 (路径+行内容+块序号) 的 SHA256 合成稳定幂等键
    /// （一行可能含多个 tool_use 块，序号消歧）。
    private static func synthOpId(path: String, line: Data, index: Int) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(path.utf8))
        hasher.update(data: line)
        hasher.update(data: Data([UInt8(index)]))
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
