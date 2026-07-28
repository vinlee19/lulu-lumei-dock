import EurekaKit
import Foundation

/// 把扁平的 `[TranscriptMessage]` 切成一轮一轮的 `TurnInput`（血缘图与逐轮诊断的输入）。
///
/// 之所以是「切」而不是「再解析一遍」：`TranscriptReader` 已经把 13 个源归一成同一个
/// 消息模型，轮边界的信息（用户消息位置、trail 容器、思考消息）全都在里面了。
/// 再开一条并行解析链意味着 2000 条消息解析两遍，且两条链的口径会慢慢漂。
///
/// **轮边界 = 真实用户消息**。这是所有源都成立的唯一判据：
///  - Claude/Codex/Qoder：`TranscriptReader` 在用户消息处重置 `trailIndex`，与这里同源；
///  - Codex 另有真 `turn_id`，但它已经在读取期用于重置 trail 了，这里不必重复消费；
///  - 其余源没有轮概念，用户消息就是唯一分界。
///
/// 首条用户消息之前的内容（会话恢复、系统注入）归入「第 0 轮」且 `promptMessageId == nil`，
/// 不丢弃 —— 那里常有 resume 摘要，丢了会让第一轮看起来凭空开始。
public enum TurnSlicer {
    public static func slice(_ messages: [TranscriptMessage]) -> [TurnInput] {
        var turns: [TurnInput] = []
        var current = TurnInput(turnIndex: 0)
        var stepIndex = 0
        var hasContent = false

        func flush() {
            // 空壳不产出（比如文件以用户消息结尾时的尾轮）
            guard hasContent || current.promptMessageId != nil else { return }
            turns.append(current)
        }

        for message in messages {
            switch message.role {
            case .user:
                // 斜杠命令回显 / 后台任务通知**不是真实提问**，不能开新轮。
                // 实勘本机 483 条字符串型 user 消息里有 240 条是这类注入（整整一半），
                // 不剥掉的话轮次列表会被一堆「0 步空轮」淹掉。
                guard let prompt = Self.realPrompt(message.text) else { continue }
                flush()
                current = TurnInput(
                    turnIndex: turns.count,
                    promptMessageId: message.id,
                    promptText: prompt,
                    startedAt: message.timestamp)
                stepIndex = 0
                hasContent = false

            case .thinking:
                current.thinkingTexts.append(message.text)
                hasContent = true
                touch(&current, message.timestamp)

            case .turnTrail:
                for step in message.steps {
                    current.steps.append(TurnInput.Step(
                        kind: step.kind, name: step.name, detail: step.detail,
                        isError: step.isError, batch: step.batch, callId: step.callId,
                        messageId: message.id, stepIndex: stepIndex,
                        subSteps: step.subSteps.map {
                            TurnInput.Step(
                                kind: $0.kind, name: $0.name, detail: $0.detail,
                                isError: $0.isError, batch: $0.batch, callId: $0.callId,
                                messageId: message.id)
                        }))
                    stepIndex += 1
                }
                if !message.steps.isEmpty { hasContent = true }
                touch(&current, message.timestamp)

            case .toolNote:
                // 无 trail 的源（opencode/grok/kimi/qwen/hermes/cursor/codebuddy…）：
                // 每条 🔧 小注就是一步。名字带 emoji 前缀，这里剥掉。
                let name = message.text.hasPrefix("🔧 ")
                    ? String(message.text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    : message.text
                current.steps.append(TurnInput.Step(
                    kind: .other, name: name, detail: "",
                    batch: stepIndex, messageId: message.id, stepIndex: stepIndex))
                stepIndex += 1
                hasContent = true
                touch(&current, message.timestamp)

            case .assistant:
                current.answerMessageIds.append(message.id)
                current.answerText = current.answerText.isEmpty
                    ? message.text : current.answerText + "\n" + message.text
                hasContent = true
                touch(&current, message.timestamp)

            case .error:
                current.errorTexts.append(message.text)
                hasContent = true
                touch(&current, message.timestamp)
            }
        }
        flush()
        return turns
    }

    /// CLI 注入进对话流、但**不是用户打字**的包裹标签（实勘 Claude；其它源没有这套）
    private static let injectedTags = [
        "local-command-caveat", "command-name", "command-message", "command-args",
        "local-command-stdout", "task-notification", "system-reminder",
    ]

    /// 剥掉注入块后剩下的真实提问；剩空则返回 nil（= 这条不是提问）。
    ///
    /// 不能见到 `<local-command-caveat>` 就整条丢：caveat 之后往往**还跟着真实提问**
    /// （斜杠命令的输出被前置注入，用户的话在后面）。所以按块剥再看剩什么。
    static func realPrompt(_ text: String) -> String? {
        var stripped = text
        for tag in injectedTags {
            stripped = removeBlocks(tag: tag, in: stripped)
        }
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 去掉所有 `<tag>…</tag>` 块（含未闭合的尾块：注入内容被截断时也不该当成提问）。
    /// 手写扫描而不是正则：内容里可能有换行与尖括号，也不把外部输入拼进正则。
    private static func removeBlocks(tag: String, in text: String) -> String {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        var result = text
        while let start = result.range(of: open) {
            if let end = result.range(of: close, range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                result.removeSubrange(start.lowerBound..<result.endIndex)
            }
        }
        return result
    }

    /// 轮结束时间取本轮见过的最后一个时间戳（多数源逐条带时间；grok 是轮级粒度）
    private static func touch(_ turn: inout TurnInput, _ timestamp: Date?) {
        guard let timestamp else { return }
        if turn.startedAt == nil { turn.startedAt = timestamp }
        if let ended = turn.endedAt, ended > timestamp { return }
        turn.endedAt = timestamp
    }
}
