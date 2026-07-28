import EurekaKit
import Foundation

/// 子代理内部轨迹加载：`<sessionId>/subagents/agent-<id>.{meta.json,jsonl}` → 按 `toolUseId` 归位。
///
/// **父子边在磁盘上是精确的**（meta 里的 `toolUseId` 就是父 transcript 里那个 `tool_use` 的 id），
/// 不需要靠时间窗启发式猜 —— `ClaudeSubagentScanner` 读到过这个字段但只用来判完成状态、
/// 构造 `SubagentInfo` 时丢掉了，这里把它用起来。
///
/// 子 agent 的 jsonl 与主 transcript **同一套 Claude 信封**，但每行 `isSidechain == true`
/// （实勘 116 行全是）—— 所以不能直接喂 `TranscriptReader.loadClaude`，它的
/// `guard isSidechain != true` 会把 assistant 行全丢掉。这里自己走一遍最小解析：
/// 只要 tool_use，不要正文（正文对血缘图没用，且会撑爆内存）。
public enum SubagentTrailLoader {
    /// 每个子代理最多收多少步。子代理动辄几十步，全收会把父图淹掉；
    /// 超出部分在 UI 上以「…等 N 步」体现。
    public static let maxStepsPerAgent = 40

    /// 主 transcript 路径 → `toolUseId: [ToolStep]`
    public static func load(mainTranscriptPath: String) -> [String: [ToolStep]] {
        let base = URL(fileURLWithPath: mainTranscriptPath)
            .deletingPathExtension()
            .appendingPathComponent("subagents", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil)
        else { return [:] }

        var result: [String: [ToolStep]] = [:]
        for meta in entries.filter({ $0.lastPathComponent.hasSuffix(".meta.json") }) {
            guard let data = try? Data(contentsOf: meta),
                let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let toolUseId = info["toolUseId"] as? String, !toolUseId.isEmpty
            else { continue }
            // agent-<id>.meta.json → agent-<id>.jsonl
            let name = meta.lastPathComponent.replacingOccurrences(
                of: ".meta.json", with: ".jsonl")
            let transcript = base.appendingPathComponent(name)
            let steps = steps(at: transcript)
            if !steps.isEmpty { result[toolUseId] = steps }
        }
        return result
    }

    /// 子 agent transcript → 工具步骤（只取 tool_use，并回填 tool_result 的失败标记）
    static func steps(at url: URL) -> [ToolStep] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        var steps: [ToolStep] = []
        var indexByCallId: [String: Int] = [:]
        var batch = 0

        for lineData in data.split(separator: UInt8(ascii: "\n")) {
            guard let root = (try? JSONSerialization.jsonObject(with: Data(lineData)))
                as? [String: Any],
                let message = root["message"] as? [String: Any],
                let blocks = message["content"] as? [[String: Any]]
            else { continue }
            switch root["type"] as? String {
            case "assistant":
                batch += 1
                for block in blocks where block["type"] as? String == "tool_use" {
                    guard steps.count < maxStepsPerAgent else { break }
                    var step = ToolStepExtractor.claude(
                        name: block["name"] as? String ?? "工具",
                        input: block["input"] as? [String: Any])
                    step.batch = batch
                    step.callId = block["id"] as? String
                    steps.append(step)
                    if let callId = step.callId { indexByCallId[callId] = steps.count - 1 }
                }
            case "user":
                for block in blocks where block["type"] as? String == "tool_result" {
                    guard block["is_error"] as? Bool == true,
                        let callId = block["tool_use_id"] as? String,
                        let index = indexByCallId[callId]
                    else { continue }
                    steps[index].isError = true
                }
            default:
                break
            }
        }
        return steps
    }
}
