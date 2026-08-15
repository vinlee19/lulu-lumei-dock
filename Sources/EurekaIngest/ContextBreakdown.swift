import Foundation

/// 会话上下文用量的分类拆解（会话详情页「上下文用量」卡片的数据模型）。
/// transcript 只记录对话正文与（部分源的）逐请求 token，系统提示词/工具 schema/MCP/技能
/// 的真实占用不可得，所以除 totalIsReal 标记的总量外，各类目均为启发式估算。
public struct ContextBreakdown: Equatable, Sendable {
    /// 五大类目，顺序与参考形态一致（堆叠条与图例共用此顺序）
    public enum Category: String, CaseIterable, Sendable {
        case systemPrompt
        case tools
        case messages
        case mcp
        case skills

        public var label: String {
            switch self {
            case .systemPrompt: return "系统提示词"
            case .tools: return "工具及子智能体"
            case .messages: return "对话消息"
            case .mcp: return "连接器及MCP"
            case .skills: return "技能"
            }
        }
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public var category: Category
        public var tokens: Int
        public var id: String { category.rawValue }

        public init(category: Category, tokens: Int) {
            self.category = category
            self.tokens = tokens
        }
    }

    /// 固定五类，按 Category 声明顺序排列
    public var entries: [Entry]
    /// 上下文占用总量：totalIsReal 时为最后一轮真实值，否则为估算合计
    public var totalTokens: Int
    /// 上下文窗口大小（百分比分母；无模型信息时回退 ContextWindows 默认值）
    public var windowTokens: Int
    /// 总量是否为最后一轮真实值（false = 纯估算，UI 标注「估算」徽章）
    public var totalIsReal: Bool

    public init(entries: [Entry], totalTokens: Int, windowTokens: Int, totalIsReal: Bool) {
        self.entries = entries
        self.totalTokens = totalTokens
        self.windowTokens = windowTokens
        self.totalIsReal = totalIsReal
    }

    public func tokens(for category: Category) -> Int {
        entries.first { $0.category == category }?.tokens ?? 0
    }
}

/// token 数启发式估算。**粗略估算**：无 tokenizer 依赖，仅供分类占比参考。
public enum TokenEstimator {
    /// ASCII 段按 ~4 字符 1 token，非 ASCII（CJK 等）按 1 字符 1 token
    public static func estimate(_ text: String) -> Int {
        var ascii = 0
        var nonASCII = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                ascii += 1
            } else {
                nonASCII += 1
            }
        }
        // ASCII 向上取整，避免短文本估成 0
        return (ascii + 3) / 4 + nonASCII
    }
}
