import CryptoKit
import Foundation
import EurekaKit
import EurekaStore

/// 扫描 ~/.codebuddy/projects/**/*.jsonl（含 `<sessionId>/subagents/agent-*.jsonl`），
/// 把 function_call 工具调用落成审计流水。schema 已对真实会话核验（2026-07）：
/// `type:"function_call"` 行带 `name` + `arguments`（JSON 字符串）+ `callId` +
/// `timestamp`（epoch 毫秒）+ `cwd`。
/// 与 CodexAuditScanner 同构：持久化 offset 增量扫描（scan_files，键加 "audit://"
/// 前缀避免与用量扫描器冲突），INSERT OR IGNORE 保证重扫幂等。
/// 两点与 codex 不同的口径：
/// - 工具词汇是 Claude 式（Read/Grep/Glob/Bash/Write/Agent…，实勘 530 行 function_call
///   无一 codex 式命名）→ arguments 解析成字典后喂 `AuditExtractor.claude(name:input:)`；
///   若喂 codex 提取器会全部落 default（kind=.other），风险规则永不命中。
/// - 子代理行内的 sessionId 是子代理自己的 id（实勘），归属父会话必须走路径推导
///   （`<slug>/<sessionId>/subagents/` 的父目录名），与 CodeBuddyUsageScanner 同口径。
public final class CodeBuddyAuditScanner {
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
    /// 与 CodeBuddyUsageScanner.sessionFiles() 同一枚举口径。
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

                // arguments 是 JSON 字符串（实勘 530/530 行皆然）；解析失败按空字典
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

    /// 会话归属：主会话文件 = <slug>/<sessionId>.jsonl（文件名 stem 即会话 id）；
    /// 子代理文件 = <slug>/<sessionId>/subagents/agent-*.jsonl（父目录名即父会话 id——
    /// 行内 sessionId 是子代理自己的，不采用）。与 CodeBuddyUsageScanner 同口径。
    private func resolveOwnership(fileURL: URL, into extra: inout FileExtra) {
        let parent = fileURL.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" {
            extra.sessionId = parent.deletingLastPathComponent().lastPathComponent
        } else {
            extra.sessionId = fileURL.deletingPathExtension().lastPathComponent
        }
    }

    /// 无 callId 的行用 (路径+行内容) 的 SHA256 合成稳定幂等键（同 CodexAuditScanner）。
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
