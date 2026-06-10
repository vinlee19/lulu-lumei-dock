import Foundation
import EurekaKit
import EurekaStore

/// 扫描 ~/.claude/projects/*/*.jsonl 的 assistant 行用量。
/// 关键不变量：**跨文件全局去重**（requestId + message.id）——
/// 流式写入会重复同一条 usage 多次，resume/fork 还会把旧行复制进新文件；
/// 本机实测单文件 1803 个重复对，不去重费用会虚高数倍。
public final class ClaudeTranscriptScanner {
    public static func defaultProjectsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CLAUDE_PROJECTS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    private let projectsRoot: URL
    private let store: EurekaStore
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(projectsRoot: URL, store: EurekaStore) {
        self.projectsRoot = projectsRoot
        self.store = store
    }

    /// 返回本轮新增的用量记录数。
    /// 必须**递归**枚举：子代理/团队会话嵌套在 <项目>/<会话>/subagents/*.jsonl
    /// （本机实测嵌套文件数是顶层的 5 倍，漏掉会少记 15-30% 用量）。
    @discardableResult
    public func scanOnce() throws -> Int {
        var inserted = 0
        let enumerator = FileManager.default.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            if item.pathExtension == "jsonl" {
                inserted += try scanFile(item)
            }
        }
        return inserted
    }

    private func scanFile(_ url: URL) throws -> Int {
        let path = url.path
        guard let info = JSONLinesReader.fileInfo(path: path) else { return 0 }
        let saved = try store.scanState.fileState(path: path)

        var offset: UInt64 = 0
        if let saved, saved.inode == info.inode, UInt64(saved.offset) <= info.size {
            offset = UInt64(saved.offset)
        }
        guard info.size > offset else { return 0 }
        guard let chunk = JSONLinesReader.read(path: path, from: offset) else { return 0 }

        // 批内合并：同 key 的流式重复行 output 递增，保留最大（最终）值
        var merged: [String: UsageRecord] = [:]
        var order: [String] = []
        for line in chunk.lines {
            guard let (key, record) = Self.parseAssistantLine(line) else { continue }
            if let prior = merged[key] {
                if record.outputTokens > prior.outputTokens {
                    merged[key] = record
                }
            } else {
                merged[key] = record
                order.append(key)
            }
        }

        var newCount = 0
        try store.scanState.transaction {
            // 去重必须跨文件全局：dedup_keys 表持久化
            let existing = try store.scanState.existingDedupKeys(order)
            let now = Date()
            for key in order {
                guard let record = merged[key] else { continue }
                if let entry = existing[key] {
                    // 已记录过：扫描赶上流式中途时记的是部分 output，用更大值回填
                    if record.outputTokens > entry.outputTokens, let recordId = entry.recordId {
                        try store.usage.updateOutputTokens(
                            recordId: recordId, outputTokens: record.outputTokens)
                        try store.scanState.upsertDedupKey(
                            key, recordId: recordId,
                            outputTokens: record.outputTokens, at: now)
                    }
                } else {
                    let recordId = try store.usage.insertReturningId(record)
                    try store.scanState.upsertDedupKey(
                        key, recordId: recordId,
                        outputTokens: record.outputTokens, at: now)
                    newCount += 1
                }
            }
            try store.scanState.setFileState(
                path: path,
                .init(inode: info.inode, offset: Int64(chunk.newOffset)))
        }
        return newCount
    }

    /// assistant 行 → (去重键, 用量记录)；synthetic 错误行与非 assistant 行返回 nil
    static func parseAssistantLine(_ line: Data) -> (key: String, record: UsageRecord)? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let root = object as? [String: Any],
            root["type"] as? String == "assistant",
            let message = root["message"] as? [String: Any],
            let model = message["model"] as? String,
            model != "<synthetic>",
            let usage = message["usage"] as? [String: Any]
        else { return nil }

        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cache1h = (usage["cache_creation"] as? [String: Any])?[
            "ephemeral_1h_input_tokens"] as? Int ?? 0
        // 全零行（如纯工具结果回包）不记
        if input == 0 && output == 0 && cacheCreation == 0 && cacheRead == 0 { return nil }

        let requestId = root["requestId"] as? String
        let messageId = message["id"] as? String
        let key: String
        if let requestId, let messageId {
            key = "c:\(requestId):\(messageId)"
        } else {
            // 缺标识的行退化为 uuid 键（不跨文件去重，但也不会丢数据）
            key = "u:\(root["uuid"] as? String ?? UUID().uuidString)"
        }

        let timestamp = (root["timestamp"] as? String).flatMap {
            isoFormatter.date(from: $0)
        } ?? Date()

        return (key, UsageRecord(
            source: .claude,
            model: model,
            timestamp: timestamp,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheCreation1hTokens: cache1h,
            cacheReadTokens: cacheRead
        ))
    }
}
