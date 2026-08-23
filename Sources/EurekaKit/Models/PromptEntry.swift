import Foundation

/// Prompt 库条目：从会话 transcript 提取的一条用户提问。
///
/// `id = "source:sessionId:msgIdx"` —— 确定性、跨扫描稳定（消息序号在文件内单调递增，
/// resume 追加只产生新 id，不重排旧 id）。收藏/标签/使用计数是用户写入的事实，
/// 提取刷新只更新正文与时间戳、绝不触碰用户标注列。
public struct PromptEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let source: AgentSource
    public let sessionId: String
    /// transcript 内消息序号（跳回会话定位用，喂 revealMessage(sessionId:messageIdx:)）
    public let messageIdx: Int
    public let text: String
    public let timestamp: Date?
    public let cwd: String?
    // MARK: 用户标注（提取不覆盖）
    public var favorite: Bool
    /// JSON 编码的标签数组（存库用）；内存中直接读写数组
    public var tags: [String]
    public var useCount: Int
    public var lastUsedAt: Date?
    /// 首次提取时间（列表默认排序键）
    public let firstSeen: Date

    public init(
        id: String, source: AgentSource, sessionId: String, messageIdx: Int,
        text: String, timestamp: Date?, cwd: String?,
        favorite: Bool = false, tags: [String] = [],
        useCount: Int = 0, lastUsedAt: Date? = nil, firstSeen: Date
    ) {
        self.id = id
        self.source = source
        self.sessionId = sessionId
        self.messageIdx = messageIdx
        self.text = text
        self.timestamp = timestamp
        self.cwd = cwd
        self.favorite = favorite
        self.tags = tags
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.firstSeen = firstSeen
    }

    /// 列表标题：首行压平空白、截断（中文按字符，60 字足够列表辨认）
    public var title: String {
        let firstLine = text.split(
            separator: "\n", maxSplits: 1, omittingEmptySubsequences: true
        ).first.map(String.init) ?? text
        let flattened = firstLine
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\t", with: " ")
        return flattened.count <= 60 ? flattened : String(flattened.prefix(60)) + "…"
    }

    /// 项目名（cwd 尾段）
    public var projectName: String? {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    public static func makeId(
        source: AgentSource, sessionId: String, messageIdx: Int
    ) -> String {
        "\(source.rawValue):\(sessionId):\(messageIdx)"
    }
}
