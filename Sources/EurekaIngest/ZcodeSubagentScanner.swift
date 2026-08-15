import Foundation
import EurekaKit

/// 扫描一个 ZCode 会话的子 agent 现场（纯函数，便于单测）。
/// 轻量快照：只读 `~/.zcode/cli/agents/<sess>/agent_*/metadata.json`，
/// 不做增量 tail（子代理 rollout/transcript 逐行入岛会造成幻影任务）。
///
/// 磁盘约定（实勘 2026-08，~/.zcode/cli/agents）：
/// - `<sess>/agent_<id>/metadata.json` = 一个子 agent：`profileSnapshot.name` 给类型
///   （如 "Explore"），`description` 给任务描述，`status`（running/completed/failed），
///   `createdAt/updatedAt/completedAt` ISO8601，`usage` 为 token 汇总（扫描器另收）。
/// - 当前活动工具：子目录 transcript.jsonl 尾窗最后一个 tool_call_scheduled/toolName。
public enum ZcodeSubagentScanner {
    /// `sessionDir` = `agents/<sess_<uuid>>/`（含各 agent_<id>/ 的目录）。
    /// `turnStartedAt` = 主会话当前 turn 起点：创建早于它的子 agent 是旧 turn 遗留，过滤。
    public static func scan(
        sessionDir: URL,
        turnStartedAt: Date? = nil,
        now: Date = Date(),
        tailBytes: Int = 32768
    ) -> [SubagentInfo] {
        let fm = FileManager.default
        let agentDirs = ((try? fm.contentsOfDirectory(
            at: sessionDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter {
                $0.lastPathComponent.hasPrefix("agent_")
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
        guard !agentDirs.isEmpty else { return [] }

        var infos: [SubagentInfo] = []
        for dir in agentDirs {
            let metaURL = dir.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let root = object as? [String: Any]
            else { continue }
            let createdAt = ZcodeRolloutDecoder.parseISO(root["createdAt"] as? String)
            // 只保留本 turn 派生的子 agent
            if let turnStartedAt, let createdAt, createdAt < turnStartedAt { continue }

            let status: SubagentInfo.Status
            switch root["status"] as? String {
            case "completed", "succeeded": status = .completed
            case "failed", "error", "cancelled": status = .failed
            case "running": status = .running
            default:
                // 缺 status 字段：按完成时间兜底，仍无则视作进行中
                status = (root["completedAt"] as? String).flatMap(ZcodeRolloutDecoder.parseISO) != nil
                    ? .completed : .running
            }

            let profile = root["profileSnapshot"] as? [String: Any]
            infos.append(SubagentInfo(
                agentId: dir.lastPathComponent,
                agentType: (profile?["name"] as? String) ?? "subagent",
                description: (root["description"] as? String) ?? "",
                status: status,
                currentActivity: status == .running
                    ? lastToolName(dir: dir, tailBytes: tailBytes) : nil,
                startedAt: createdAt,
                finishedAt: nil))  // 快照可去重：finishedAt 统一留 nil（与 kimi/claude 扫描器同例）
        }

        // 稳定排序：开始时间在前，缺时间者按 agentId 兜底
        return infos.sorted {
            switch ($0.startedAt, $1.startedAt) {
            case let (l?, r?) where l != r: return l < r
            default: return $0.agentId < $1.agentId
            }
        }
    }

    /// 子代理 transcript.jsonl 尾窗最后一个工具名（tool_call_scheduled.toolName）
    private static func lastToolName(dir: URL, tailBytes: Int) -> String? {
        let transcript = dir.appendingPathComponent("transcript.jsonl")
        guard
            let handle = FileHandle(forReadingAtPath: transcript.path),
            let size = try? handle.seekToEnd(), size > 0
        else { return nil }
        defer { try? handle.close() }
        let length = min(size, UInt64(tailBytes))
        guard (try? handle.seek(toOffset: size - length)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }
        var last: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let root = object as? [String: Any],
                root["type"] as? String == "tool_call_scheduled",
                let payload = root["payload"] as? [String: Any],
                let name = payload["toolName"] as? String, !name.isEmpty
            else { continue }
            last = name
        }
        return last
    }
}
