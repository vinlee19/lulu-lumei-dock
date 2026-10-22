import Foundation

/// Reads a generated summary back into parts the review page can lay out: `##` sections, the
/// "AI proposed → I chose — Why" items and the "worth keeping" candidates. Everything is
/// best-effort: what doesn't parse stays Markdown, so custom templates and loosely formatted
/// output always render.
public enum SummaryDocument {
    public struct Section: Equatable, Sendable {
        public var heading: String
        public var body: String
    }

    /// Splits on `## ` headings (deeper headings stay inside their section). Text before the first
    /// heading is returned as the preamble.
    public static func sections(_ markdown: String) -> (preamble: String, sections: [Section]) {
        var preamble: [Substring] = []
        var sections: [Section] = []
        var heading: String?
        var body: [Substring] = []
        var inFence = false
        func flush() {
            if let heading {
                sections.append(Section(
                    heading: heading,
                    body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            body = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            if !inFence, line.hasPrefix("## ") {
                flush()
                heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                continue
            }
            if heading == nil { preamble.append(line) } else { body.append(line) }
        }
        flush()
        return (preamble.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), sections)
    }

    /// Top-level list items of a section body, markers and continuation lines joined
    public static func bullets(_ body: String) -> [String] {
        var items: [String] = []
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let item = listItemText(trimmed), !line.hasPrefix("  "), !line.hasPrefix("\t") {
                items.append(item)
            } else if !trimmed.isEmpty, let last = items.indices.last {
                items[last] += " " + (listItemText(trimmed) ?? trimmed)
            }
        }
        return items
    }

    /// `- x`, `* x`, `1. x` → `x`
    static func listItemText(_ line: String) -> String? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return String(line.dropFirst(2)) }
        if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber),
           !line[..<dot].isEmpty, line[line.index(after: dot)...].hasPrefix(" ") {
            return String(line[line.index(dot, offsetBy: 2)...])
        }
        return nil
    }

    /// True when a section only says there is nothing to report
    public static func isEmptySection(_ body: String) -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-*. 。"))
            .lowercased()
        return text.isEmpty || ["none", "n/a", "无", "没有", "暂无"].contains(text)
    }

    // MARK: - Choices

    public struct Choice: Equatable, Sendable {
        public enum Verdict: Equatable, Sendable { case accepted, rejected, modified, other }
        public var proposal: String
        public var decision: String
        /// nil when the model wrote that the reason isn't stated (or omitted it)
        public var reason: String?
        public var verdict: Verdict
        public var references: [Int]
    }

    private static let proposedLabels = ["AI proposed", "AI 提议", "AI 提出", "AI 建议"]
    private static let choseLabels = ["I chose", "我选择", "我的选择", "我选了"]
    private static let whyLabels = ["Why", "原因", "理由", "为什么"]

    /// Items written as `**AI proposed:** … → **I chose:** … — **Why:** …`; others are skipped
    public static func choices(_ body: String) -> [Choice] {
        bullets(body).compactMap(choice(from:))
    }

    static func choice(from item: String) -> Choice? {
        guard let proposedRange = labelRange(in: item, labels: proposedLabels),
              let choseRange = labelRange(in: item, labels: choseLabels, after: proposedRange.upperBound)
        else { return nil }
        let whyRange = labelRange(in: item, labels: whyLabels, after: choseRange.upperBound)
        let proposal = clean(item[proposedRange.upperBound..<choseRange.lowerBound])
        let decisionEnd = whyRange?.lowerBound ?? item.endIndex
        let decision = clean(item[choseRange.upperBound..<decisionEnd])
        var reason = whyRange.map { clean(item[$0.upperBound...]) }
        if let text = reason, notStated(text) { reason = nil }
        guard !proposal.isEmpty, !decision.isEmpty else { return nil }
        return Choice(
            proposal: proposal, decision: decision, reason: reason,
            verdict: verdict(of: decision), references: SummaryReferences.ids(in: item))
    }

    /// The range of `**Label:**` (colon inside or outside the bold, ASCII or full-width)
    private static func labelRange(
        in text: String, labels: [String], after start: String.Index? = nil
    ) -> Range<String.Index>? {
        let searchStart = start ?? text.startIndex
        var best: Range<String.Index>?
        for label in labels {
            for form in ["**\(label):**", "**\(label)：**", "**\(label)**:", "**\(label)**："] {
                if let range = text.range(of: form, options: .caseInsensitive, range: searchStart..<text.endIndex),
                   best == nil || range.lowerBound < best!.lowerBound {
                    best = range
                }
            }
        }
        return best
    }

    /// Trims separators the template puts between the parts (`→`, `—`, `-`) and whitespace
    private static func clean(_ text: Substring) -> String {
        text.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "→—–-|;；,，"))
            .trimmingCharacters(in: .whitespaces)
    }

    static func notStated(_ text: String) -> Bool {
        let lower = SummaryReferences.strip(text).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " .。\"“”'"))
        return lower.isEmpty || lower == "reason not stated" || lower == "not stated"
            || lower.contains("未说明") || lower.contains("没有说明") || lower.contains("未提及原因")
    }

    /// Verdict words a decision may start with, in both languages
    private static let verdictWords = [
        "accepted", "adopted", "rejected", "declined", "modified", "overrode", "changed",
        "采纳", "接受", "同意", "否决", "拒绝", "没有采纳", "未采纳", "修改", "调整", "部分采纳", "推翻",
    ]

    /// The decision without its leading verdict word and separator ("rejected, one row instead"
    /// → "one row instead"); empty when the decision is only the verdict
    public static func droppingVerdictWord(_ decision: String) -> String {
        let lower = decision.lowercased()
        guard let word = verdictWords.sorted(by: { $0.count > $1.count }).first(where: { lower.hasPrefix($0) })
        else { return decision }
        return String(decision.dropFirst(word.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,，:：;；-—–。."))
    }

    static func verdict(of decision: String) -> Choice.Verdict {
        let lower = decision.lowercased()
        if lower.hasPrefix("rejected") || lower.hasPrefix("declined") || decision.hasPrefix("否决")
            || decision.hasPrefix("拒绝") || decision.hasPrefix("没有采纳") || decision.hasPrefix("未采纳") {
            return .rejected
        }
        if lower.hasPrefix("modified") || lower.hasPrefix("overrode") || lower.hasPrefix("changed")
            || decision.hasPrefix("修改") || decision.hasPrefix("调整") || decision.hasPrefix("改为")
            || decision.hasPrefix("部分采纳") || decision.hasPrefix("推翻") {
            return .modified
        }
        if lower.hasPrefix("accepted") || lower.hasPrefix("adopted") || decision.hasPrefix("采纳")
            || decision.hasPrefix("接受") || decision.hasPrefix("同意") {
            return .accepted
        }
        return .other
    }

    // MARK: - Worth keeping

    public struct Candidate: Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, Sendable { case memory, rule }
        public var kind: Kind
        public var title: String
        public var content: String
        public var references: [Int]

        /// Stable within a run (kind + title), used to remember per-item decisions
        public var id: String { kind.rawValue + ":" + title.lowercased() }
    }

    private static let kindLabels: [(Candidate.Kind, [String])] = [
        (.memory, ["Memory", "记忆"]),
        (.rule, ["Rule", "规则"]),
    ]

    /// Items written as `**Memory** | title | content` or `**Rule** | title | content`
    public static func candidates(_ body: String) -> [Candidate] {
        bullets(body).compactMap { item in
            for (kind, labels) in kindLabels {
                for label in labels where item.hasPrefix("**\(label)**") {
                    let parts = item.dropFirst(label.count + 4)
                        .split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    let fields = parts.first == "" || parts.first == ":" ? Array(parts.dropFirst()) : parts
                    guard fields.count >= 2 else { return nil }
                    let title = SummaryReferences.strip(fields[0])
                    let content = fields[1...].joined(separator: " | ")
                    guard !title.isEmpty, !content.isEmpty else { return nil }
                    return Candidate(
                        kind: kind, title: title, content: SummaryReferences.strip(content),
                        references: SummaryReferences.ids(in: content))
                }
            }
            return nil
        }
    }
}
