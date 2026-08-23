import EurekaKit
import Foundation

/// Prompt 库采集端：从会话 transcript 提取用户提问（`role == .user`）。
///
/// 复用 `TranscriptReader` 的全部源加载器——12 个源可直接提取（含共享 DB 的
/// opencode/hermes/cursor/zcode，按 sessionId 查询即可）；antigravity（protobuf）
/// 与 trae（SQLCipher）各只回一条 toolNote，天然提取不出任何条目。
public enum PromptExtractor {
    /// 单会话提取：全量解析 transcript、过滤用户消息。
    /// 空白文本跳过；`firstSeen` 由调用方传入（同一批扫描共享一个时间戳，排序稳定）。
    public static func extract(from session: AgentSessionInfo, at now: Date) -> [PromptEntry] {
        let messages = TranscriptReader.load(session: session).messages
        return messages.compactMap { message in
            guard message.role == .user else { return nil }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return PromptEntry(
                id: PromptEntry.makeId(
                    source: session.source, sessionId: session.id, messageIdx: message.id),
                source: session.source,
                sessionId: session.id,
                messageIdx: message.id,
                text: text,
                timestamp: message.timestamp,
                cwd: session.cwd,
                firstSeen: now)
        }
    }
}
