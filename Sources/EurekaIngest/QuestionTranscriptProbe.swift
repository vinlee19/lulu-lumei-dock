import EurekaKit
import Foundation

/// Whether a pending question was already settled (answered / declined) in Claude's own
/// confirmation UI: watches the session transcript for that question's tool_result.
///
/// When the user answers first in Claude, Claude doesn't terminate the waiting `lululumei-ask`, so
/// the island card has to be withdrawn from here. The transcript doesn't depend on relay hooks, so
/// this holds even without Claude hooks installed.
/// - the question's tool_use: a main-chain assistant line with `name == "AskUserQuestion"` whose
///   question text matches what the hook received;
/// - settled: a main-chain user line contains a tool_result pointing at it, with a line time no
///   earlier than the question (if the same question was asked twice, the earlier tool_result is in
///   the transcript too; the time check excludes it).
///
/// For each question, the first read covers only the transcript tail `initialTailBytes` (the
/// tool_use is written before the hook starts); each later read only covers newly appended bytes.
public final class QuestionTranscriptProbe {
    private struct Cursor {
        var offset: UInt64
        /// When reading starts mid-file, the first chunk is a partial line and must be dropped
        var skipPartialLine: Bool
        /// The incomplete line from the last read, waiting to be completed next time
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
            // File was rewritten: read again from the tail, keeping already-recognized tool_uses
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

    /// Keep read progress only for questions still pending
    public func retain(only ids: Set<String>) {
        cursors = cursors.filter { ids.contains($0.key) }
    }

    private static let toolName = Data("AskUserQuestion".utf8)
    private static let toolResult = Data("tool_result".utf8)

    private func scan(_ line: Data, question: PendingQuestion, cursor: inout Cursor) {
        // The vast majority of lines contain neither: filter by bytes first to skip JSON parsing
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
