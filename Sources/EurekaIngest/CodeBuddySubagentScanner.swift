import Foundation
import EurekaKit

/// 扫描一个 CodeBuddy 会话的子 agent 现场（纯函数，便于单测）。
///
/// 磁盘约定（实勘 2026-07，~/.codebuddy）：CodeBuddy 没有 Claude 式 meta.json，
/// 派生信息全在父 transcript `<sessionId>.jsonl` 里：
/// - `function_call` 行 name ∈ {TaskCreate, Agent, AgentSwarm}：`callId` + `arguments`
///   （JSON 字符串：Agent 带 description/prompt/subagent_type，TaskCreate 带 subject/description）。
/// - 配对 `function_call_result` 行（同 callId）：`status:"completed"` → 完成，其它 → 失败。
/// - 子 agent transcript 是 `subagents/agent-<hex>.jsonl`，文件名与 callId 无映射；
///   运行中 agent 的当前工具靠 prompt 前缀匹配子文件首条 user 消息定位（实勘可一一对应），
///   取其尾窗最后一个 function_call 名。agent id = callId。
public enum CodeBuddySubagentScanner {
    /// `sessionDir` = `<slug>/<sessionId>/`（与 `<sessionId>.jsonl` 同级的目录）。
    /// `parentTranscript` = `<sessionId>.jsonl`（读尾窗找 function_call/result 对）。
    /// `turnStartedAt` = 当前 turn 起点：只保留本 turn 派生的调用（call 时间 ≥ 它），nil 不过滤。
    /// tailBytes 默认 1MB：派生调用必须整轮留在窗口内，而 codebuddy 单轮的工具结果
    /// 常带大段文件内容（实勘一轮可达数百 KB），256KB 窗口会让子 agent 中途掉出列表。
    public static func scan(
        sessionDir: URL,
        parentTranscript: URL?,
        turnStartedAt: Date? = nil,
        tailBytes: Int = 1048576
    ) -> [SubagentInfo] {
        guard let parentTranscript,
              let data = tail(of: parentTranscript, bytes: tailBytes)
        else { return [] }

        struct Spawn {
            var agentType: String
            var description: String
            var prompt: String?
            var startedAt: Date?
        }
        var spawns: [String: Spawn] = [:]   // callId → 派生信息
        var order: [String] = []
        var results: [String: Bool] = [:]   // callId → 是否失败（仅已回包的调用）

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let type = root["type"] as? String
            else { continue }
            switch type {
            case "function_call":
                guard
                    let name = root["name"] as? String,
                    ["TaskCreate", "Agent", "AgentSwarm"].contains(name),
                    let callId = root["callId"] as? String, !callId.isEmpty
                else { continue }
                let ts = CodeBuddyTranscriptDecoder.timestamp(root)
                // 只保留本 turn 派生的子 agent
                if let turnStartedAt, let ts, ts < turnStartedAt { continue }
                let args = CodeBuddyTranscriptDecoder.toolCall(root)?.args ?? [:]
                let description = (args["description"] as? String)
                    ?? (args["subject"] as? String) ?? ""
                // TaskCreate 无 subagent_type 字段，按工具名兜底
                let agentType = (args["subagent_type"] as? String)
                    ?? (name == "TaskCreate" ? "task" : "agent")
                if spawns[callId] == nil { order.append(callId) }
                spawns[callId] = Spawn(
                    agentType: agentType, description: description,
                    prompt: args["prompt"] as? String, startedAt: ts)
            case "function_call_result":
                guard let callId = root["callId"] as? String else { continue }
                // 实勘终态为 "completed"；其它非缺失状态一律按失败
                if let status = root["status"] as? String {
                    results[callId] = status != "completed"
                }
            default:
                continue
            }
        }
        guard !spawns.isEmpty else { return [] }

        // 有运行中的 agent 才建 prompt→子文件 索引（省 IO）
        let subagentsDir = sessionDir.appendingPathComponent("subagents", isDirectory: true)
        var transcripts: [(firstPrompt: String, url: URL)]?
        var infos: [SubagentInfo] = []
        for callId in order {
            guard let spawn = spawns[callId] else { continue }
            let status: SubagentInfo.Status
            if let isError = results[callId] {
                status = isError ? .failed : .completed
            } else {
                status = .running
            }

            var currentActivity: String?
            if status == .running, let prompt = spawn.prompt, !prompt.isEmpty {
                if transcripts == nil { transcripts = subagentTranscripts(in: subagentsDir) }
                let needle = String(prompt.prefix(64))
                if let match = transcripts?.first(where: { $0.firstPrompt.hasPrefix(needle) }) {
                    currentActivity = lastToolUse(in: match.url, tailBytes: 32768)
                }
            }

            infos.append(SubagentInfo(
                agentId: callId,
                agentType: spawn.agentType,
                description: spawn.description,
                status: status,
                currentActivity: currentActivity,
                startedAt: spawn.startedAt,
                finishedAt: nil))  // 与 claude 扫描器同例：留 nil 保证快照可去重
        }

        // 稳定排序：开始时间在前，缺时间者按 agentId 兜底
        return infos.sorted {
            switch ($0.startedAt, $1.startedAt) {
            case let (l?, r?) where l != r: return l < r
            default: return $0.agentId < $1.agentId
            }
        }
    }

    // MARK: - 解析

    /// subagents/ 下各 agent-*.jsonl 的首条 user 正文（用于 prompt 前缀定位 callId 对应的 transcript）
    private static func subagentTranscripts(in dir: URL) -> [(firstPrompt: String, url: URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("agent-") && $0.pathExtension == "jsonl" } ?? []
        var out: [(String, URL)] = []
        for file in files {
            guard let head = head(of: file, bytes: 8192),
                  let line = head.split(separator: UInt8(ascii: "\n")).first,
                  let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let text = CodeBuddyTranscriptDecoder.userText(root)
            else { continue }
            out.append((text, file))
        }
        return out
    }

    /// 子 agent transcript 尾窗里最后一个 function_call 的工具名
    private static func lastToolUse(in url: URL, tailBytes: Int) -> String? {
        guard let data = tail(of: url, bytes: tailBytes) else { return nil }
        var last: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                root["type"] as? String == "function_call",
                let name = root["name"] as? String
            else { continue }
            last = name
        }
        return last
    }

    /// 读文件头部 bytes（不足则全读）
    private static func head(of url: URL, bytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes), !data.isEmpty else { return nil }
        return data
    }

    /// 读文件尾部 bytes（不足则全读），与 ClaudeSubagentScanner 一致的尾窗读法
    private static func tail(of url: URL, bytes: Int) -> Data? {
        guard
            let handle = FileHandle(forReadingAtPath: url.path),
            let size = try? handle.seekToEnd(), size > 0
        else { return nil }
        defer { try? handle.close() }
        let length = min(size, UInt64(bytes))
        guard (try? handle.seek(toOffset: size - length)) != nil else { return nil }
        return try? handle.readToEnd()
    }
}
