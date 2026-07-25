import Foundation

/// 把用户 prompt / 消息压成卡片标题：取首个非空行，截断补省略号
func summarizeTitle(_ text: String, maxLength: Int = 80) -> String? {
    let firstLine = text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty }
    guard var line = firstLine else { return nil }
    // 本地命令/系统注入的 XML 包裹内容不当标题
    if line.hasPrefix("<") { return nil }
    if line.count > maxLength {
        line = String(line.prefix(maxLength)) + "…"
    }
    return line
}

/// 计划标题收紧：整段提示词当标题在列表里读不出重点（常见 80 字硬截断，还会从词中间断开）。
/// 优先截到 maxLength 内的首个句读边界（。！？；.!?; 优于 ，,），都没有再退回硬截断补省略号。
/// 纯字符串逻辑，可单测。
public func tightenPlanTitle(_ raw: String, maxLength: Int = 46) -> String {
    var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // 已经是硬截断产物（末尾省略号）→ 去掉再按句读重切，避免「…」叠加
    while line.hasSuffix("…") || line.hasSuffix("...") {
        line = String(line.dropLast(line.hasSuffix("…") ? 1 : 3))
            .trimmingCharacters(in: .whitespaces)
    }
    let strong = Set<Character>("。！？；.!?;")
    let weak = Set<Character>("，,、")
    let head = Array(line.prefix(maxLength))
    // 句末标点：截到它之前（标题不带句号）
    if let index = head.lastIndex(where: { strong.contains($0) }), index > 0 {
        return String(head[0..<index]).trimmingCharacters(in: .whitespaces)
    }
    // 逗号/顿号：至少要留下有意义的一截，太靠前的不算
    if let index = head.lastIndex(where: { weak.contains($0) }), index >= 8 {
        return String(head[0..<index]).trimmingCharacters(in: .whitespaces)
    }
    if line.count > maxLength {
        return String(head).trimmingCharacters(in: .whitespaces) + "…"
    }
    return line
}
