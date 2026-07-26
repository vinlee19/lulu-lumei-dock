import Foundation
import EurekaKit

/// 扫描一个 Kimi 会话的子 agent 现场（纯函数，便于单测）。轻量快照：只读各 agent
/// wire.jsonl 的头 + 小尾窗，不做增量 tail（主 wire 的 tail 归 KimiWireTailer，
/// 子 wire 入事件流会造成幻影任务）。
///
/// 磁盘约定（实勘 2026-07，~/.kimi-code）：
/// - `agents/<id>/wire.jsonl`（id != "main"）= 一个子 agent；上级 `state.json` 的
///   `agents.<id>.type` 给类型（"sub"），`createdAt` 给会话起点。
/// - 描述取子 wire 头部首个 turn.prompt 正文（剥掉 `<git-context>` 包裹后摘要；
///   注意子 agent 的 prompt origin.kind 是 system_trigger，不能走 decoder 的用户轮判定）。
/// - 状态：尾窗里未收尾的轮次/轮内心跳 + wire mtime 活着（默认 30 分钟内有写入）= 运行中，
///   mtime 已沉寂说明进程死在中途，按完成收尾；终轮 finishReason=error → 失败。
/// - 当前工具 = 尾窗最后一个 tool.call 名。
public enum KimiSubagentScanner {
    /// `sessionDir` = `sessions/<ws>/<session>/`（含 state.json 与 agents/ 的目录）。
    /// `turnStartedAt` = 主会话当前 turn 起点：wire 创建早于它的子 agent 是旧 turn 遗留，过滤。
    /// `liveWindow` = 判定"还活着"的写入新鲜窗口（死会话的轮次永不收尾，靠它避免永远 running）。
    /// headBytes 默认 64KB：wire 前奏（config.update 的 systemPrompt 等）单行可达数十 KB，
    /// 实勘首个 turn.prompt 落在 ~40KB 内。
    public static func scan(
        sessionDir: URL,
        turnStartedAt: Date? = nil,
        now: Date = Date(),
        liveWindow: TimeInterval = 1800,
        headBytes: Int = 65536,
        tailBytes: Int = 32768
    ) -> [SubagentInfo] {
        let fm = FileManager.default
        let agentsDir = sessionDir.appendingPathComponent("agents", isDirectory: true)
        let agentDirs = ((try? fm.contentsOfDirectory(
            at: agentsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter {
                $0.lastPathComponent != "main"
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
        guard !agentDirs.isEmpty else { return [] }

        let types = agentTypes(sessionDir: sessionDir)
        var infos: [SubagentInfo] = []
        for dir in agentDirs {
            let wire = dir.appendingPathComponent("wire.jsonl")
            guard
                let values = try? wire.resourceValues(
                    forKeys: [.creationDateKey, .contentModificationDateKey]),
                let mtime = values.contentModificationDate
            else { continue }
            let createdAt = values.creationDate
            // 只保留本 turn 派生的子 agent（wire 创建于 prompt 之后）
            if let turnStartedAt, let createdAt, createdAt < turnStartedAt { continue }

            let firstPrompt = head(of: wire, bytes: headBytes).flatMap(firstPromptText)
            var lastStarted: Date?
            var lastFinished: (at: Date, isError: Bool)?
            var lastProgress: Date?  // 轮内心跳（tool.call / 中间步）的最新时刻
            var lastTool: String?
            if let data = tail(of: wire, bytes: tailBytes) {
                for line in data.split(separator: UInt8(ascii: "\n")) {
                    guard
                        let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                    else { continue }
                    if let (name, _) = KimiWireDecoder.toolCall(root) { lastTool = name }
                    for event in KimiWireDecoder.decode(root: root, sessionId: "", cwd: nil) {
                        switch event.kind {
                        case .taskStarted:
                            lastStarted = event.timestamp
                        case .taskFinished(let outcome, _, _):
                            lastFinished = (event.timestamp, outcome == .error)
                        case .activity, .waiting, .toolPending, .compacting:
                            lastProgress = event.timestamp
                        default:
                            break
                        }
                    }
                }
            }

            let status: SubagentInfo.Status
            let fresh = now.timeIntervalSince(mtime) < liveWindow
            let openTurn = lastStarted != nil
                && (lastFinished.map { $0.at < lastStarted! } ?? true)
            let activeProgress = lastProgress != nil
                && (lastFinished.map { $0.at < lastProgress! } ?? true)
            if openTurn || activeProgress {
                // 轮次未收尾：wire 还在写 = 运行中；已沉寂 = 进程死在中途，按完成收尾
                status = fresh ? .running : .completed
            } else if let finished = lastFinished {
                status = finished.isError ? .failed : .completed
            } else {
                // 尾窗没有任何轮次痕迹：活着 = 刚派生；沉寂 = 老古董按完成
                status = fresh ? .running : .completed
            }

            infos.append(SubagentInfo(
                agentId: dir.lastPathComponent,
                agentType: types[dir.lastPathComponent] ?? "sub",
                description: firstPrompt.flatMap(descriptionText) ?? "",
                status: status,
                currentActivity: status == .running ? lastTool : nil,
                startedAt: createdAt ?? lastStarted,
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

    /// state.json 的 agents.<id>.type 表（读取失败给空表，调用方兜底 "sub"）
    private static func agentTypes(sessionDir: URL) -> [String: String] {
        let url = sessionDir.appendingPathComponent("state.json")
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let agents = root["agents"] as? [String: Any]
        else { return [:] }
        var map: [String: String] = [:]
        for (id, entry) in agents {
            if let type = (entry as? [String: Any])?["type"] as? String, !type.isEmpty {
                map[id] = type
            }
        }
        return map
    }

    /// wire 头部首个 turn.prompt 的正文（input=[{type:text,text}] 拼接）。
    /// 注意不能用 KimiWireDecoder.promptText：子 agent 的首轮 origin.kind 是
    /// system_trigger(name=subagent)，decoder 的用户轮判定会把它过滤掉。
    private static func firstPromptText(head: Data) -> String? {
        for line in head.split(separator: UInt8(ascii: "\n")) {
            guard
                let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                root["type"] as? String == "turn.prompt",
                let blocks = root["input"] as? [[String: Any]]
            else { continue }
            let text = blocks
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// 派生 prompt → 岛上展示的一行描述：剥 `<git-context>…</git-context>` 前缀、
    /// 剥 Agent 工具模板带的 "Thoroughness: …." 起首句，再取摘要
    static func descriptionText(_ prompt: String) -> String? {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<git-context>"),
           let close = text.range(of: "</git-context>") {
            text = String(text[close.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("Thoroughness: "),
           let dot = text.firstIndex(of: "."), text.distance(from: text.startIndex, to: dot) < 40 {
            text = String(text[text.index(after: dot)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return summarizeTitle(text)
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
