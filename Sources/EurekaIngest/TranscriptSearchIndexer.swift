import EurekaKit
import EurekaStore
import Foundation

/// 跨会话全文搜索索引器：发现 transcript → size+mtime 指纹比对 → 变更文件整体重建 docs。
/// 只索引 user / assistant 文本（工具轨迹噪音大且可从会话页展开查看）；
/// opencode（全部会话共享一个库文件，指纹无法区分）与 antigravity（protobuf 无明文）暂不索引。
public final class TranscriptSearchIndexer {
    /// 单条消息入索引的截断上限（字符），防单条超长撑爆索引体积
    static let maxDocChars = 8192

    private let store: EurekaStore

    public init(store: EurekaStore) {
        self.store = store
    }

    /// 按默认磁盘根路径发现全部会话并索引一轮；返回本轮重建的文件数
    @discardableResult
    public func indexOnce() -> Int {
        var sessions = ClaudeSessionIndexer.index(
            projectsRoot: ClaudeSessionBootstrap.defaultProjectsRoot())
        sessions += CodexSessionIndexer.index(
            sessionsRoot: CodexRolloutTailer.defaultSessionsRoot())
        sessions += GrokSessionIndexer.index(sessionsRoot: GrokPaths.sessionsRoot())
        sessions += KimiSessionIndexer.index(sessionsRoot: KimiPaths.sessionsRoot())
        return indexOnce(sessions: sessions)
    }

    /// 注入会话列表的索引一轮（测试入口；生产走 indexOnce()）
    @discardableResult
    public func indexOnce(sessions: [AgentSessionInfo]) -> Int {
        let supported = sessions.filter {
            $0.source != .opencode && $0.source != .antigravity
        }
        guard let fingerprints = try? store.search.fileFingerprints() else { return 0 }
        var rebuilt = 0
        let fm = FileManager.default
        for session in supported {
            let path = session.transcriptPath
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value
            else { continue }
            let mtime = ((attrs[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970
            if let known = fingerprints[path], known.size == size, known.mtime == mtime {
                continue
            }
            let docs = Self.docs(for: session)
            if (try? store.search.replaceDocs(
                path: path, source: session.source.rawValue, sessionId: session.id,
                size: size, mtime: mtime, docs: docs)) != nil {
                rebuilt += 1
            }
        }
        try? store.search.prune(keeping: Set(supported.map(\.transcriptPath)))
        return rebuilt
    }

    /// 一个会话的可索引文档：与会话详情页同一 TranscriptReader（message.id 天然对齐，命中可直接跳消息）
    static func docs(for session: AgentSessionInfo) -> [TranscriptSearchDoc] {
        TranscriptReader.load(session: session).messages.compactMap { message in
            guard message.role == .user || message.role == .assistant else { return nil }
            let text = String(message.text.prefix(maxDocChars))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return TranscriptSearchDoc(
                messageIdx: message.id,
                role: message.role == .user ? "user" : "assistant",
                ts: message.timestamp,
                text: text)
        }
    }
}
