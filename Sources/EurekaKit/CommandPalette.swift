import Foundation

/// ⌘K 全局搜索的纯数据模型 + 聚合逻辑（合并去重、snippet 就近裁剪）。
///
/// 放 EurekaKit 而不是与之配套的 `CommandPaletteService`（Sources/EurekaApp）同层，
/// 是吃过 `KnowledgeSearchIndexer` 的教训：`eureka-tests` 只能链接库目标
/// （EurekaKit/EurekaStore/EurekaIngest/…），链不到 app 壳 `eureka`
/// （`.executableTarget`）的目标码——类型检查能过，`swift run eureka-tests` 链接期必炸
/// `Undefined symbols`。这里的两个函数无 IO、无 AppKit，纯值类型 + 纯函数，天然该落在
/// 这一层；真正持有 `EurekaStore`/防抖队列/`@Published` 状态的服务留在 app 壳，
/// 用 typealias 转发这里的类型（同 `TurnGraph` 的先例）。
public enum CommandPalette {
    public enum Kind: Int, CaseIterable, Sendable {
        case session, skill, memory, instruction, plan

        public var label: String {
            switch self {
            case .session: return "会话"
            case .skill: return "技能"
            case .memory: return "记忆"
            case .instruction: return "指令"
            case .plan: return "计划"
            }
        }

        /// reveal 通知里 userInfo["kind"] 用的字符串（PopoverRootView 路由消费，
        /// CommandPaletteView 发送端复用，避免两端手写字面量拼写漂移）。
        /// 会话/计划的 reveal 通知不带 kind，故为 nil。
        public var revealKind: String? {
            switch self {
            case .session, .plan: return nil
            case .skill: return "skill"
            case .memory: return "memory"
            case .instruction: return "instruction"
            }
        }
    }

    public struct Hit: Identifiable, Equatable, Sendable {
        public var kind: Kind
        /// 去重键：知识面/计划 = 文件路径；会话 = session id
        public var key: String
        public var title: String
        public var subtitle: String?
        /// 正文命中的上下文片段（元数据命中为 nil）
        public var snippet: String?
        public var sessionId: String?
        /// 会话正文命中时的消息定位
        public var messageIdx: Int?
        public var id: String { "\(kind.rawValue):\(key)" }

        public init(
            kind: Kind, key: String, title: String, subtitle: String?,
            snippet: String?, sessionId: String?, messageIdx: Int?
        ) {
            self.kind = kind
            self.key = key
            self.title = title
            self.subtitle = subtitle
            self.snippet = snippet
            self.sessionId = sessionId
            self.messageIdx = messageIdx
        }
    }

    /// 合并去重：同 (kind, key) 取先出现者（元数据在前 → 标题命中优先），每组截断
    public static func merge(_ hits: [Hit], perKindCap: Int) -> [Hit] {
        var seen = Set<String>()
        var byKind: [Kind: [Hit]] = [:]
        for hit in hits {
            guard seen.insert(hit.id).inserted else { continue }
            if byKind[hit.kind, default: []].count < perKindCap {
                byKind[hit.kind, default: []].append(hit)
            }
        }
        return Kind.allCases.flatMap { byKind[$0] ?? [] }
    }

    /// 就近裁剪：命中词前后各 radius 字符
    public static func snippet(_ text: String, query: String, radius: Int = 40) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = flat.range(of: query, options: .caseInsensitive) else {
            return String(flat.prefix(radius * 2))
        }
        let start = flat.index(
            range.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(
            range.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        return String(flat[start..<end])
    }
}
