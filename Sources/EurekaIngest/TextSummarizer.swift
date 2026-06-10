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
