import Foundation

/// 一条记忆的用途分类：取自 markdown frontmatter 里的 `metadata.type`
/// （Claude 的记忆写手约定四类：user / feedback / project / reference）。
///
/// `other` 承接**没写 type 的旧记忆**（本机 97 个文件里 29 个如此）——
/// 不去猜类别：猜错会把「用户偏好」混进「项目进展」，比空着更误导。
public enum MemoryType: String, Codable, Sendable, CaseIterable {
    case user
    case feedback
    case project
    case reference
    case other

    /// 宽松解析：大小写与前后空白无关；不认识的值一律归 `other`（不丢条目）。
    public init(loose raw: String?) {
        let key = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = MemoryType(rawValue: key) ?? .other
    }

    public var label: String {
        switch self {
        case .user: return "用户画像"
        case .feedback: return "工作方式"
        case .project: return "项目进展"
        case .reference: return "外部资料"
        case .other: return "未分类"
        }
    }

    /// 图谱泳道的**固定**左右顺序。写死而不按条数排：同一个记忆库两次打开
    /// 泳道位置必须一致，否则用户建立的空间记忆每次刷新都作废。
    public var laneOrder: Int {
        switch self {
        case .feedback: return 0
        case .project: return 1
        case .user: return 2
        case .reference: return 3
        case .other: return 4
        }
    }

    /// SF Symbol（图谱节点与列表 chip 共用）
    public var icon: String {
        switch self {
        case .user: return "person.crop.circle"
        case .feedback: return "quote.bubble"
        case .project: return "shippingbox"
        case .reference: return "link"
        case .other: return "questionmark.circle"
        }
    }
}
