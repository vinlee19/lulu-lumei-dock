import EurekaKit
import Foundation

/// Prompt 库采集端：从会话 transcript 提取用户提问（`role == .user`）。
///
/// 复用 `TranscriptReader` 的全部源加载器——12 个源可直接提取（含共享 DB 的
/// opencode/hermes/cursor/zcode，按 sessionId 查询即可）；antigravity（protobuf）
/// 与 trae（SQLCipher）各只回一条 toolNote，天然提取不出任何条目。
public enum PromptExtractor {
    /// 单会话提取：全量解析 transcript、过滤用户消息，并做三层排噪
    /// （实勘 2395 条里 12.4% 是伪用户消息 —— 复用库存它们毫无意义）：
    /// 1. `TurnSlicer.realPrompt` 按块剥注入标签（caveat 后跟真实提问的能保留），剩空跳过；
    /// 2. `PromptClassifier.isInjectedArtifact` 补 TurnSlicer 清单外的前缀
    ///    （bash-input / Codex 环境上下文）与裸斜杠命令；
    /// 3. `truncateForStorage` 截断超长粘贴（实勘最长 1.98MB 日志）。
    /// `firstSeen` 由调用方传入（同一批扫描共享一个时间戳，排序稳定）。
    public static func extract(from session: AgentSessionInfo, at now: Date) -> [PromptEntry] {
        extract(
            messages: TranscriptReader.load(session: session).messages,
            session: session, at: now)
    }

    /// 纯函数重载：调用方自己 load 好 messages（提取与轮次评价共享同一次解析——
    /// transcript 全量重解析是提取管线的主要成本，不能为评价再 load 一遍）
    public static func extract(
        messages: [TranscriptMessage], session: AgentSessionInfo, at now: Date
    ) -> [PromptEntry] {
        return messages.compactMap { message in
            guard message.role == .user else { return nil }
            guard let real = TurnSlicer.realPrompt(message.text) else { return nil }
            guard !PromptClassifier.isInjectedArtifact(real) else { return nil }
            let text = PromptClassifier.truncateForStorage(real)
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
