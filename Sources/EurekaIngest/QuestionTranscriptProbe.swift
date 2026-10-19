import EurekaKit
import Foundation

/// 等待中的提问是否已在 Claude 自己的确认界面里了结（答了 / 拒了）：盯着会话转录，等这道题的 tool_result。
///
/// 用户在 Claude 里先答时，Claude 不会终止等待中的 `lululumei-ask`，岛上的卡要靠这里撤掉。
/// 转录不依赖 relay hooks，没装 Claude hooks 时同样成立。
/// - 这道题的 tool_use：主链 assistant 行里 `name == "AskUserQuestion"`、问题原文与 hook 收到的一致；
/// - 了结：主链 user 行里出现指向它的 tool_result，且行时间不早于提问
///   （同样的题问过两次时，上一次的 tool_result 也在转录里，靠时间排除）。
///
/// 每道题首次只读转录尾部 `initialTailBytes`（tool_use 在 hook 启动前就已写入），之后每次只读新追加的字节。
public final class QuestionTranscriptProbe {
    private struct Cursor {
        var offset: UInt64
        /// 从文件中间开始读时，第一段是半截行，要丢掉
        var skipPartialLine: Bool
        /// 上次读到的不完整行，等下次补齐
        var carry = Data()
        var toolUseIds: Set<String> = []
        var settled = false
    }

    private let initialTailBytes: UInt64
    private var cursors: [String: Cursor] = [:]

    public init(initialTailBytes: UInt64 = 1 << 20) {
        self.initialTailBytes = initialTailBytes
    }

    public func isSettled(_ question: PendingQuestion) -> Bool {
        if cursors[question.id]?.settled == true { return true }
        guard
            let path = question.transcriptPath,
            let handle = FileHandle(forReadingAtPath: path),
            let size = try? handle.seekToEnd()
        else { return false }
        defer { try? handle.close() }

        let tailStart = size > initialTailBytes ? size - initialTailBytes : 0
        var cursor = cursors[question.id] ?? Cursor(offset: tailStart, skipPartialLine: tailStart > 0)
        if size < cursor.offset {
            // 文件被重写：重新从尾部读，已认出的 tool_use 保留
            cursor.offset = tailStart
            cursor.skipPartialLine = tailStart > 0
            cursor.carry = Data()
        }
        guard size > cursor.offset,
              (try? handle.seek(toOffset: cursor.offset)) != nil,
              let appended = try? handle.read(upToCount: Int(size - cursor.offset))
        else {
            cursors[question.id] = cursor
            return false
        }
        cursor.offset += UInt64(appended.count)

        var lines = (cursor.carry + appended).split(
            separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        cursor.carry = Data(lines.removeLast())
        if cursor.skipPartialLine, !lines.isEmpty {
            lines.removeFirst()
            cursor.skipPartialLine = false
        }
        for line in lines where !cursor.settled {
            scan(Data(line), question: question, cursor: &cursor)
        }
        cursors[question.id] = cursor
        return cursor.settled
    }

    /// 只保留还在等待的题的读取进度
    public func retain(only ids: Set<String>) {
        cursors = cursors.filter { ids.contains($0.key) }
    }

    private static let toolName = Data("AskUserQuestion".utf8)
    private static let toolResult = Data("tool_result".utf8)

    private func scan(_ line: Data, question: PendingQuestion, cursor: inout Cursor) {
        // 绝大多数行两样都不含：先按字节筛，省掉 JSON 解析
        let mentionsTool = line.range(of: Self.toolName) != nil
        guard mentionsTool || line.range(of: Self.toolResult) != nil,
              let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              root["isSidechain"] as? Bool != true,
              let content = (root["message"] as? [String: Any])?["content"] as? [[String: Any]]
        else { return }

        switch root["type"] as? String {
        case "assistant" where mentionsTool:
            let asked = question.questions.map(\.question)
            for block in content
            where block["type"] as? String == "tool_use" && block["name"] as? String == "AskUserQuestion" {
                let input = block["input"] as? [String: Any]
                let texts = (input?["questions"] as? [[String: Any]])?.compactMap { $0["question"] as? String }
                if texts == asked, let id = block["id"] as? String {
                    cursor.toolUseIds.insert(id)
                }
            }
        case "user":
            guard
                !cursor.toolUseIds.isEmpty,
                let raw = root["timestamp"] as? String,
                let at = TranscriptReader.parseTimestamp(raw), at >= question.createdAt
            else { return }
            let ids = cursor.toolUseIds
            if content.contains(where: { block in
                block["type"] as? String == "tool_result"
                    && (block["tool_use_id"] as? String).map(ids.contains) == true
            }) {
                cursor.settled = true
            }
        default:
            return
        }
    }
}
