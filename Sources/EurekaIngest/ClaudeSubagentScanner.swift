import Foundation
import EurekaKit

/// 扫描一个 Claude 会话的子 agent 现场（纯函数，便于单测）。
///
/// 磁盘约定（当前版 Claude Code 实地核实）：
/// - `<sessionDir>/subagents/agent-<id>.meta.json` = `{agentType, description, toolUseId}`，派生即建。
/// - `<sessionDir>/subagents/agent-<id>.jsonl` = 子 agent transcript，尾部最后一个 tool_use 名 = 当前工具。
/// - 完成信号：父 transcript 出现 `tool_result`（`tool_use_id == toolUseId`），`is_error` → 失败。
///   大结果会被卸载到 `<sessionDir>/tool-results/<toolUseId>.txt`（兜底完成判据）。
public enum ClaudeSubagentScanner {
    /// `sessionDir` = `<项目>/<sessionId>/`（与 `<sessionId>.jsonl` 同级的目录）。
    /// `parentTranscript` = `<sessionId>.jsonl`（读尾窗找 tool_result）。
    /// `turnStartedAt` = 当前 turn 起点（prompt 时间）：subagents/ 目录跨 turn 累积，
    /// 只保留本 turn 创建的子 agent（meta 创建时间 ≥ 它），nil 则不过滤。
    public static func scan(
        sessionDir: URL,
        parentTranscript: URL?,
        turnStartedAt: Date? = nil,
        tailBytes: Int = 262144
    ) -> [SubagentInfo] {
        let fm = FileManager.default
        let subagentsDir = sessionDir.appendingPathComponent("subagents", isDirectory: true)
        let metas = (try? fm.contentsOfDirectory(
            at: subagentsDir, includingPropertiesForKeys: [.creationDateKey]))?
            .filter { $0.lastPathComponent.hasSuffix(".meta.json") } ?? []
        guard !metas.isEmpty else { return [] }  // Codex / 无子 agent

        // 父 transcript 尾窗里的 tool_result：tool_use_id → is_error
        let completion = parentTranscript.map { toolResults(in: $0, tailBytes: tailBytes) } ?? [:]
        let resultsDir = sessionDir.appendingPathComponent("tool-results", isDirectory: true)

        var infos: [SubagentInfo] = []
        for meta in metas {
            let createdAt = (try? meta.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            // 只保留本 turn 派生的子 agent（meta 创建于 prompt 之后）
            if let turnStartedAt, let createdAt, createdAt < turnStartedAt { continue }
            guard
                let data = try? Data(contentsOf: meta),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let toolUseId = obj["toolUseId"] as? String
            else { continue }
            let agentId = meta.lastPathComponent
                .replacingOccurrences(of: "agent-", with: "")
                .replacingOccurrences(of: ".meta.json", with: "")
            let agentType = obj["agentType"] as? String ?? "agent"
            let description = obj["description"] as? String ?? ""

            let status: SubagentInfo.Status
            if let isError = completion[toolUseId] {
                status = isError ? .failed : .completed
            } else if fm.fileExists(
                atPath: resultsDir.appendingPathComponent("\(toolUseId).txt").path) {
                status = .completed  // 内联结果滚出尾窗，但卸载文件还在
            } else {
                status = .running
            }

            // 只为运行中的子 agent 读其 transcript 尾部取当前工具（省 IO）
            var currentActivity: String?
            if status == .running {
                let jsonl = subagentsDir.appendingPathComponent("agent-\(agentId).jsonl")
                currentActivity = lastToolUse(in: jsonl, tailBytes: 32768)
            }

            infos.append(SubagentInfo(
                agentId: agentId,
                agentType: agentType,
                description: description,
                status: status,
                currentActivity: currentActivity,
                startedAt: createdAt,
                finishedAt: nil))  // UI 不展示完成时刻；留 nil 保证扫描结果可去重
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

    /// 父 transcript 尾窗里所有 tool_result 的 tool_use_id → is_error
    private static func toolResults(in url: URL, tailBytes: Int) -> [String: Bool] {
        guard let data = tail(of: url, bytes: tailBytes) else { return [:] }
        var map: [String: Bool] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                root["type"] as? String == "user",
                let message = root["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { continue }
            for block in content where block["type"] as? String == "tool_result" {
                if let tid = block["tool_use_id"] as? String {
                    map[tid] = (block["is_error"] as? Bool) ?? false
                }
            }
        }
        return map
    }

    /// 子 agent transcript 尾窗里最后一个 assistant tool_use 的工具名
    private static func lastToolUse(in url: URL, tailBytes: Int) -> String? {
        guard let data = tail(of: url, bytes: tailBytes) else { return nil }
        var last: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                root["type"] as? String == "assistant",
                let message = root["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { continue }
            for block in content where block["type"] as? String == "tool_use" {
                if let name = block["name"] as? String { last = name }
            }
        }
        return last
    }

    /// 读文件尾部 bytes（不足则全读），与 ClaudeSessionBootstrap 一致的尾窗读法
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
