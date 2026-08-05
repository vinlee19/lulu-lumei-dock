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
    private let projectResolver = ProjectResolver()
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
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

        // 批内合并：同 key 的流式重复行 output 递增，保留最大（最终）值；
        // 顺路数真实用户 prompt（对话数，零额外 IO）
        var merged: [String: UsageRecord] = [:]
        var order: [String] = []
        var promptCount = 0
        // 工具/技能/插件调用：**逐 tool_use id 累积**，不按 assistant 去重键归并 ——
        // Claude Code 每个 content block 单独写一行却共享同一 (requestId, message.id)，
        // 按 key 覆盖会让同消息的 Skill 行被后面的 Bash 行顶掉（本机实测 78 条技能调用丢 10 条）。
        var toolCalls: [(
            id: String, kind: String, name: String, day: String, ts: Double, tokens: Int
        )] = []
        var seenToolIds: Set<String> = []
        // 斜杠命令：(uuid, day, name)，用 s:<uuid> 去重后计数
        var commands: [(uuid: String, day: String, name: String)] = []
        for line in chunk.lines {
            guard
                let object = try? JSONSerialization.jsonObject(with: line),
                let root = object as? [String: Any]
            else { continue }
            if Self.isRealPrompt(root) { promptCount += 1 }
            if let command = Self.extractCommand(root) {
                let day = (root["timestamp"] as? String)
                    .flatMap { Self.isoFormatter.date(from: $0) }
                    .map { Self.dayFormatter.string(from: $0) }
                    ?? Self.dayFormatter.string(from: Date())
                commands.append((command.uuid, day, command.name))
            }
            guard let parsed = Self.parseAssistantLine(root) else { continue }
            let key = parsed.key
            var record = parsed.record
            // 项目名按仓库根归组（子目录/子模块的会话归到仓库名下）
            record.project = projectResolver.projectName(forCwd: record.project) ?? record.project
            if let message = root["message"] as? [String: Any] {
                // 触发时 token = 该 assistant 行 token 合计（≈调用时上下文规模，仅 Claude 可得）；
                // 同行多 tool_use 时按行归给每个调用，技能场景重叠可忽略
                let lineTokens = record.inputTokens + record.outputTokens
                    + record.cacheCreationTokens + record.cacheReadTokens
                let day = Self.dayFormatter.string(from: record.timestamp)
                let ts = record.timestamp.timeIntervalSince1970
                for call in Self.extractToolCalls(message) {
                    // 无 id 的 tool_use 无法去重（重扫会翻倍）→ 保守不计数
                    guard let id = call.id, !id.isEmpty else { continue }
                    guard seenToolIds.insert(id).inserted else { continue }  // 文件内同 id 只算一次
                    toolCalls.append((id, call.kind, call.name, day, ts, lineTokens))
                }
            }
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
        // 会话 = 文件（文件名即 session id）；对话数按文件计，口径不随归属改写
        let sessionId = url.deletingPathExtension().lastPathComponent
        // 调用计数归属的会话：子代理转录归到父会话（见 attributionSessionId）
        let callSessionId = Self.attributionSessionId(for: url, root: projectsRoot)
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
            // 工具/技能/插件/子代理调用：用 tc:<tool_use id> 跨文件去重，**与消息级用量去重解耦** ——
            // 挂在"首次入库"分支上会漏：某轮只读到消息的 thinking/text 行就消费了消息级键，
            // 下轮读到同消息的 tool_use 行时走回填分支，调用永久无归属。
            if !toolCalls.isEmpty {
                let callKeys = toolCalls.map { "tc:\($0.id)" }
                let existingCalls = try store.scanState.existingDedupKeys(callKeys)
                for call in toolCalls {
                    let dkey = "tc:\(call.id)"
                    guard existingCalls[dkey] == nil else { continue }
                    try store.toolCalls.bump(
                        day: call.day, source: .claude, kind: call.kind, name: call.name,
                        ts: call.ts, tokens: call.tokens, session: callSessionId)
                    try store.scanState.upsertDedupKey(
                        dkey, recordId: nil, outputTokens: 0, at: now)
                }
            }
            // 斜杠命令：用 s:<uuid> 跨文件去重，新键才计数
            if !commands.isEmpty {
                let commandKeys = commands.map { "s:\($0.uuid)" }
                let existingCommands = try store.scanState.existingDedupKeys(commandKeys)
                for command in commands {
                    let dkey = "s:\(command.uuid)"
                    guard existingCommands[dkey] == nil else { continue }
                    try store.toolCalls.bump(
                        day: command.day, source: .claude, kind: "command", name: command.name,
                        session: callSessionId)
                    try store.scanState.upsertDedupKey(
                        dkey, recordId: nil, outputTokens: 0, at: now)
                }
            }
            try store.scanState.setFileState(
                path: path,
                .init(inode: info.inode, offset: Int64(chunk.newOffset)))
            // offset==0 是全量重扫 → 覆盖而非累加
            try store.sessionStats.recordPrompts(
                path: path,
                sessionId: sessionId,
                count: promptCount,
                reset: offset == 0)
        }
        return newCount
    }

    /// 调用计数归属的会话 id：子代理转录（`<父会话>/subagents/**/agent-*.jsonl`）归到**父会话**。
    /// 文件名派生的 `agent-<hash>` 不是真会话，`ClaudeSessionIndexer` 只枚举一层、永远解析不到，
    /// 直接用它做反查会给死跳转。父会话就是 `subagents` 目录的上一级 —— 注意 subagents 下还会
    /// 再套一层 `workflows/wf_<id>/`（本机 4 个目录如此），所以必须按路径组件定位 subagents，
    /// 只看父目录名会漏掉这一形态。查找从项目根之下开始，免得根路径自己带同名目录时误判。
    static func attributionSessionId(for url: URL, root: URL) -> String {
        let fileName = url.deletingPathExtension().lastPathComponent
        let components = url.pathComponents
        let rootDepth = root.pathComponents.count
        guard components.count > rootDepth,
              let marker = components[rootDepth...].firstIndex(of: "subagents"),
              marker > rootDepth
        else { return fileName }
        return components[marker - 1]
    }

    /// assistant 行的 tool_use 块 → (id, kind, name)：
    /// Skill→(skill,技能名) / mcp__ 前缀→(mcp, server.tool) / Task|Agent→(agent,子代理类型) / 其余→(tool,工具名)。
    /// id 是 tool_use 块自带的唯一标识（`toolu_xxx`），调用计数按它去重；缺失则为 nil。
    static func extractToolCalls(
        _ message: [String: Any]
    ) -> [(id: String?, kind: String, name: String)] {
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var result: [(String?, String, String)] = []
        for block in blocks where block["type"] as? String == "tool_use" {
            guard let name = block["name"] as? String, !name.isEmpty else { continue }
            let id = block["id"] as? String
            let input = block["input"] as? [String: Any]
            if name == "Skill" {
                result.append((id, "skill", (input?["skill"] as? String) ?? "?"))
            } else if name.hasPrefix("mcp__") {
                let comps = name.components(separatedBy: "__").filter { !$0.isEmpty }
                var server = comps.count >= 2 ? comps[1] : name
                if server.hasPrefix("claude_ai_") {
                    server = String(server.dropFirst("claude_ai_".count))
                }
                let tool = comps.count >= 3 ? comps[2...].joined(separator: "__") : ""
                result.append((id, "mcp", tool.isEmpty ? server : "\(server).\(tool)"))
            } else if name == "Task" || name == "Agent" {
                result.append((id, "agent", (input?["subagent_type"] as? String) ?? "?"))
            } else {
                result.append((id, "tool", name))
            }
        }
        return result
    }

    /// user 行内嵌的斜杠命令：`<command-name>/xx</command-name>` → (uuid, 命令名)
    static func extractCommand(_ root: [String: Any]) -> (uuid: String, name: String)? {
        guard root["type"] as? String == "user",
              root["isMeta"] as? Bool != true,
              let uuid = root["uuid"] as? String,
              let message = root["message"] as? [String: Any],
              let content = message["content"] as? String,
              let start = content.range(of: "<command-name>"),
              let end = content.range(
                of: "</command-name>", range: start.upperBound..<content.endIndex)
        else { return nil }
        let name = String(content[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return (uuid, name)
    }

    /// 真实用户 prompt（对话轮次）：非 meta、content 是字符串（tool_result 是数组）
    static func isRealPrompt(_ root: [String: Any]) -> Bool {
        guard root["type"] as? String == "user",
              root["isMeta"] as? Bool != true,
              let message = root["message"] as? [String: Any]
        else { return false }
        return message["content"] is String
    }

    /// assistant 行 → (去重键, 用量记录)；synthetic 错误行与非 assistant 行返回 nil
    static func parseAssistantLine(_ root: [String: Any]) -> (key: String, record: UsageRecord)? {
        guard
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
            // 暂存原始 cwd，scanFile 经 ProjectResolver 归组为仓库名
            project: root["cwd"] as? String,
            sessionId: root["sessionId"] as? String,
            timestamp: timestamp,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheCreation1hTokens: cache1h,
            cacheReadTokens: cacheRead
        ))
    }
}
