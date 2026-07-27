import CryptoKit
import EurekaKit
import EurekaStore
import Foundation

/// 扫描 `~/.qwen/projects/<slug>/chats/<uuid>.jsonl`，把 `functionCall` 落成审计流水。
///
/// 行是 Claude 式混血信封，需要的字段全在行上（实勘 v0.2 2026-07）：
/// `{type:"assistant", sessionId, cwd, timestamp, message:{parts:[{functionCall:{id,name,args}}]}}`。
/// 与 Codex/Grok 不同，`args` 已是**结构化对象**而不是 JSON 字符串。
///
/// 词表同 Cursor/Grok 那套 snake_case（实勘 `read_file`(file_path) / `grep_search`(pattern,path) /
/// `agent`(subagent_type) / `ask_user_question`），故复用 `AuditExtractor.qwen` → 内部走
/// 共享的 snake_case 映射。⚠️ 本机 Qwen 用量很少（只见到 4 种工具 28 次调用），
/// 词表**未穷尽**；认不出的名字会落 `.other` + 首个字符串参数，不会丢行。
///
/// 增量与其它审计扫描器一致：`scan_files` 持久化 offset（键带 `audit://` 前缀），
/// `INSERT OR IGNORE` 保证重扫幂等；幂等键取 `functionCall.id`，缺失时按行合成 hash。
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

    /// `projects/<slug>/chats/*.jsonl`（不按 mtime 过滤 —— scan_files 水位让老文件近乎零成本）
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
        // 会话 id 兜底：文件名 stem（行上通常自带 sessionId）
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
