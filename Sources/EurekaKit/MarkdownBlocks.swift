import Foundation

/// 轻量 Markdown 块级解析（会话对话渲染用）：只切块级结构，
/// 行内样式（粗体/行内代码/链接）交给视图层的 AttributedString(markdown:)。
/// 容错优先：解析失败/不认识的行绝不吞内容，一律落到 paragraph。
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case codeBlock(language: String?, code: String)
    case listItem(ordered: Bool, index: Int, text: String, indent: Int)
    case quote(String)
    case divider
    case table(header: [String], rows: [[String]])
}

public enum MarkdownBlockParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var quoteLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines = []
        }
        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            blocks.append(.quote(quoteLines.joined(separator: "\n")))
            quoteLines = []
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
        }

        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 围栏代码块（``` / ~~~，捕获语言；未闭合容错到文末）
            if let fence = fenceMarker(trimmed) {
                flushAll()
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    let codeTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    if codeTrimmed.hasPrefix(fence) {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.codeBlock(
                    language: language.isEmpty ? nil : language,
                    code: codeLines.joined(separator: "\n")))
                continue
            }

            // 空行：段落/引用分界
            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }

            // 引用（连续行合并）
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var content = trimmed.dropFirst()
                if content.hasPrefix(" ") { content = content.dropFirst() }
                quoteLines.append(String(content))
                index += 1
                continue
            }
            flushQuote()

            // 分隔线
            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            // 标题
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            // GFM 表格：当前行含 `|` 且下一行是分隔行（|---|---|）
            if trimmed.contains("|"), index + 1 < lines.count,
               isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                index += 2  // 跳过表头行 + 分隔行
                while index < lines.count {
                    let rowTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    guard rowTrimmed.contains("|"), !rowTrimmed.isEmpty else { break }
                    rows.append(tableCells(rowTrimmed))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // 列表项（前导空格 2 格一级，封顶 3 级）
            if let item = parseListItem(line) {
                flushParagraph()
                blocks.append(item)
                index += 1
                continue
            }

            paragraphLines.append(line)
            index += 1
        }
        flushAll()
        return blocks
    }

    // MARK: - 行判定

    /// GFM 表格分隔行：含 `-`，且去掉 `|`/`:`/`-`/空格后为空（如 `|---|:--:|`）
    static func isTableSeparator(_ trimmed: String) -> Bool {
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    /// 拆表格行单元格：按 `|` 分割，去首尾竖线产生的空段，trim
    static func tableCells(_ line: String) -> [String] {
        var cells = line.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    /// 围栏起始行 → 围栏标记（"```" / "~~~"），否则 nil
    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func isDivider(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        for marker: Character in ["-", "*", "_"] {
            if trimmed.allSatisfy({ $0 == marker }) { return true }
        }
        return false
    }

    private static func parseHeading(_ trimmed: String) -> MarkdownBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: hashes.count, text: text)
    }

    private static func parseListItem(_ line: String) -> MarkdownBlock? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let indent = min(3, leadingSpaces / 2)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // 无序：- / * / + 后接空格
        for marker in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(marker) {
                let text = String(trimmed.dropFirst(2))
                    .trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                return .listItem(ordered: false, index: 0, text: text, indent: indent)
            }
        }
        // 有序：N. 或 N) 后接空格
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3,
           let number = Int(digits) {
            let rest = trimmed.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                let text = String(rest.dropFirst(2))
                    .trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                return .listItem(ordered: true, index: number, text: text, indent: indent)
            }
        }
        return nil
    }
}
