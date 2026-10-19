import Foundation

/// Lightweight block-level Markdown parsing (for rendering session conversations): splits only
/// block structure; inline styles (bold / inline code / links) are left to the view layer's
/// AttributedString(markdown:). Fault-tolerant first: a parse failure or unknown line never
/// swallows content -- it always falls through to paragraph.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case codeBlock(language: String?, code: String)
    case listItem(ordered: Bool, index: Int, text: String, indent: Int, check: TaskCheck?)
    case quote(String)
    case divider
    case table(header: [String], rows: [[String]])

    /// GFM task list state: `- [ ]` / `- [~]` / `- [x]` ([~] = in progress, a Codex work-list
    /// convention)
    public enum TaskCheck: Equatable, Sendable {
        case todo
        case inProgress
        case done
    }
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

            // Fenced code block (``` / ~~~, captures the language; unclosed tolerated to EOF)
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

            // Blank line: paragraph/quote boundary
            if trimmed.isEmpty {
                flushAll()
                index += 1
                continue
            }

            // Quote (consecutive lines merged)
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var content = trimmed.dropFirst()
                if content.hasPrefix(" ") { content = content.dropFirst() }
                quoteLines.append(String(content))
                index += 1
                continue
            }
            flushQuote()

            // Divider
            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            // Heading
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            // GFM table: current line contains `|` and the next is a separator row (|---|---|)
            if trimmed.contains("|"), index + 1 < lines.count,
               isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                index += 2  // skip the header row + separator row
                while index < lines.count {
                    let rowTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    guard rowTrimmed.contains("|"), !rowTrimmed.isEmpty else { break }
                    rows.append(tableCells(rowTrimmed))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // List item (2 leading spaces per level, capped at 3 levels)
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

    // MARK: - Line classification

    /// GFM table separator row: contains `-` and is empty after removing `|`/`:`/`-`/spaces
    /// (e.g. `|---|:--:|`)
    static func isTableSeparator(_ trimmed: String) -> Bool {
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        return trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    /// Splits a table row into cells: split on `|`, drop empty segments from the outer pipes,
    /// trim
    static func tableCells(_ line: String) -> [String] {
        var cells = line.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    /// Fence opening line → fence marker ("```" / "~~~"), otherwise nil
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

        // Unordered: - / * / + followed by a space
        for marker in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(marker) {
                let raw = String(trimmed.dropFirst(2))
                    .trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty else { return nil }
                let (text, check) = splitTaskCheck(raw)
                guard !text.isEmpty else { return nil }
                return .listItem(
                    ordered: false, index: 0, text: text, indent: indent, check: check)
            }
        }
        // Ordered: N. or N) followed by a space
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3,
           let number = Int(digits) {
            let rest = trimmed.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                let raw = String(rest.dropFirst(2))
                    .trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty else { return nil }
                let (text, check) = splitTaskCheck(raw)
                guard !text.isEmpty else { return nil }
                return .listItem(
                    ordered: true, index: number, text: text, indent: indent, check: check)
            }
        }
        return nil
    }

    /// Task list marker: `[ ] xxx` / `[x] xxx` / `[X] xxx` / `[~] xxx` → (text, state);
    /// no marker → (original, nil)
    private static func splitTaskCheck(_ raw: String) -> (String, MarkdownBlock.TaskCheck?) {
        let markers: [(String, MarkdownBlock.TaskCheck)] = [
            ("[ ]", .todo), ("[x]", .done), ("[X]", .done), ("[~]", .inProgress),
        ]
        for (marker, check) in markers where raw.hasPrefix(marker) {
            let rest = raw.dropFirst(marker.count)
            guard rest.isEmpty || rest.hasPrefix(" ") else { continue }
            return (rest.trimmingCharacters(in: .whitespaces), check)
        }
        return (raw, nil)
    }
}
