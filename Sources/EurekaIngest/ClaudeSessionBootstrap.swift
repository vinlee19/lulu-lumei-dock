import Foundation
import EurekaKit

/// 启动时重建 Claude 会话现场（Codex 由 rollout tailer 的初见扫描负责）：
/// app 启动前就在跑的会话，其 UserPromptSubmit 早已消费/丢失，
/// 心跳又要等下一次工具调用结束才来——长命令/纯生成期间会一直隐形。
///
/// 判定：transcript 尾部最后一个真实用户 prompt 之后，没有 turn 结束标记 → turn 仍在飞行中。
/// 结束标记：`stop_reason == "end_turn"` 的主链 assistant 行 / 用户中断行 / API 错误行 /
/// `turn_duration`（只有 CLI 入口写；桌面端 `entrypoint: claude-desktop` 从不写）。
public enum ClaudeSessionBootstrap {
    /// 默认 ~/.claude/projects（EUREKA_CLAUDE_PROJECTS 覆盖，与用量扫描器同约定）
    public static func defaultProjectsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CLAUDE_PROJECTS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// 扫描近期活跃的会话 transcript，合成状态重建事件。
    /// 只看 projects/<项目>/<会话>.jsonl 两层（subagents/ 是子代理侧链，不是会话）。
    public static func discover(
        projectsRoot: URL,
        idleWindow: TimeInterval = 1800,
        now: Date = Date()
    ) -> [TaskEvent] {
        let fm = FileManager.default
        var events: [TaskEvent] = []
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
        for projectDir in projectDirs {
            let files = (try? fm.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                guard now.timeIntervalSince(mtime) < idleWindow else { continue }
                events.append(contentsOf: inspectSession(fileURL: file, mtime: mtime))
            }
        }
        return events
    }

    /// 会话现场快照（尾窗分类结果）
    public struct Snapshot: Equatable {
        public var sessionId: String
        public var cwd: String?
        public var running: Bool
        public var promptAt: Date?
        public var promptText: String?
        public var turnEndAt: Date?
        /// 最近一个结束标记代表的结局（用户中断 → interrupted，其余 → success；
        /// API 错误由 EventPipeline 的 ClaudeErrorSniffer 升级为 error）
        public var turnEndOutcome: TaskOutcome?
        public var aiTitle: String?
        public var contextPercent: Double?
        public var earliestAt: Date?

        /// 任务名：剥掉注入块（后台任务回报 `<task-notification>` 等）后再摘要；
        /// 剥空 → nil，TaskStore 沿用会话上一个标题
        public var promptTitle: String? {
            promptText.flatMap { TurnSlicer.realPrompt($0) }.flatMap { summarizeTitle($0) }
        }
    }

    /// 单个 transcript 的现场判定（公开供测试）。
    public static func inspectSession(
        fileURL: URL, mtime: Date, tailBytes: Int = 262144
    ) -> [TaskEvent] {
        guard let snapshot = classify(fileURL: fileURL, tailBytes: tailBytes) else { return [] }

        func event(_ kind: TaskEvent.Kind, at date: Date) -> TaskEvent {
            TaskEvent(
                source: .claude, sessionId: snapshot.sessionId, kind: kind,
                timestamp: date, cwd: snapshot.cwd, transcriptPath: fileURL.path)
        }

        var events: [TaskEvent] = []
        if snapshot.running {
            let title = snapshot.promptTitle
            // 开始时间：prompt 时间 → 尾窗最早时间（至少不低估时长）→ mtime
            events.append(event(
                .taskStarted(title: title),
                at: snapshot.promptAt ?? snapshot.earliestAt ?? mtime))
        } else {
            events.append(event(.sessionStarted, at: mtime))
        }
        if let aiTitle = snapshot.aiTitle {
            events.append(event(.titleUpdate(title: aiTitle), at: mtime))
        }
        if let percent = snapshot.contextPercent {
            events.append(event(.contextUpdate(percent: percent), at: mtime))
        }
        return events
    }

    /// 尾窗分类：turn 是否在飞行中。
    /// 尾窗要够大：长 turn 期间真实 prompt 可能在数百 KB 之外。
    public static func classify(fileURL: URL, tailBytes: Int = 262144) -> Snapshot? {
        guard
            let handle = FileHandle(forReadingAtPath: fileURL.path),
            let size = try? handle.seekToEnd(), size > 0
        else { return nil }
        defer { try? handle.close() }
        let length = min(size, UInt64(tailBytes))
        guard (try? handle.seek(toOffset: size - length)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var sessionId: String?
        var cwd: String?
        var aiTitle: String?
        var lastPromptAt: Date?
        var lastPromptText: String?
        var lastTurnEndAt: Date?
        var lastTurnEndOutcome: TaskOutcome?
        var contextPercent: Double?
        /// 尾部是否有主链执行痕迹（assistant/tool_result）——超长 turn 中段的判据
        var hasMainChainActivity = false
        var earliestAt: Date?

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let root = object as? [String: Any],
                let type = root["type"] as? String
            else { continue }
            if sessionId == nil { sessionId = root["sessionId"] as? String }
            if cwd == nil { cwd = root["cwd"] as? String }
            let timestamp = (root["timestamp"] as? String).flatMap {
                isoFormatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
            }
            if let timestamp, earliestAt == nil { earliestAt = timestamp }

            switch type {
            case "ai-title":
                aiTitle = root["aiTitle"] as? String

            case "user":
                guard root["isMeta"] as? Bool != true,
                      let message = root["message"] as? [String: Any]
                else { continue }
                // 真实 prompt：content 是字符串；数组（tool_result）算执行痕迹
                if let content = message["content"] as? String {
                    lastPromptAt = timestamp
                    lastPromptText = content
                } else if isInterruptMarker(message["content"]) {
                    // 用户按 Esc 中断：之后不会再有 end_turn / Stop
                    lastTurnEndAt = timestamp ?? lastTurnEndAt
                    lastTurnEndOutcome = .interrupted
                } else {
                    hasMainChainActivity = true
                }

            case "system":
                if root["subtype"] as? String == "turn_duration" {
                    lastTurnEndAt = timestamp
                    lastTurnEndOutcome = .success
                }

            case "assistant":
                guard root["isSidechain"] as? Bool != true,
                      let message = root["message"] as? [String: Any]
                else { continue }
                // API 错误行也意味着 turn 结束（不会再有 turn_duration）
                if root["isApiErrorMessage"] as? Bool == true
                    || message["model"] as? String == "<synthetic>" {
                    lastTurnEndAt = timestamp ?? lastTurnEndAt
                    lastTurnEndOutcome = .success
                    continue
                }
                hasMainChainActivity = true
                // 模型主动收尾（不再调工具）= turn 结束；桌面端没有 turn_duration，这是它唯一的结束标记
                if message["stop_reason"] as? String == "end_turn" {
                    lastTurnEndAt = timestamp ?? lastTurnEndAt
                    lastTurnEndOutcome = .success
                }
                if let usage = message["usage"] as? [String: Any] {
                    let used = (usage["input_tokens"] as? Int ?? 0)
                        + (usage["cache_read_input_tokens"] as? Int ?? 0)
                        + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    if used > 0 {
                        contextPercent = ContextWindows.percent(
                            used: used, model: message["model"] as? String)
                    }
                }

            default:
                break
            }
        }

        guard let sessionId else { return nil }
        let running: Bool
        if let promptAt = lastPromptAt {
            // prompt 可见：之后没有结束标记 → 在飞行中
            running = lastTurnEndAt.map { $0 < promptAt } ?? true
        } else if lastTurnEndAt != nil {
            // 只看到结束标记 → 上一轮已收尾
            running = false
        } else {
            // 超长 turn 中段：prompt 和结束标记都滚出尾窗，满屏执行痕迹 → 在飞行中
            running = hasMainChainActivity
        }

        return Snapshot(
            sessionId: sessionId,
            cwd: cwd,
            running: running,
            promptAt: lastPromptAt,
            promptText: lastPromptText,
            turnEndAt: lastTurnEndAt,
            turnEndOutcome: lastTurnEndOutcome,
            aiTitle: aiTitle,
            contextPercent: contextPercent,
            earliestAt: earliestAt
        )
    }

    /// 中断行：content 数组里的 text 以 "[Request interrupted by user" 开头
    /// （含 "... for tool use]" 变体）
    private static func isInterruptMarker(_ content: Any?) -> Bool {
        guard let items = content as? [[String: Any]] else { return false }
        return items.contains {
            $0["type"] as? String == "text"
                && ($0["text"] as? String)?.hasPrefix("[Request interrupted by user") == true
        }
    }
}
