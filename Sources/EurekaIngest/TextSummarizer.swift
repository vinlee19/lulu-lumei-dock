import Foundation

/// Condenses a user prompt / message into a card title: first non-empty line, truncated with an
/// ellipsis
func summarizeTitle(_ text: String, maxLength: Int = 80) -> String? {
    let firstLine = text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty }
    guard var line = firstLine else { return nil }
    // Content wrapped in XML by local commands / system injection isn't used as a title
    if line.hasPrefix("<") { return nil }
    if line.count > maxLength {
        line = String(line.prefix(maxLength)) + "…"
    }
    return line
}

/// Tightens plan titles: a whole prompt as a title is unreadable in a list (often hard-cut at 80
/// chars, even mid-word). Prefers the first sentence-punctuation boundary within maxLength
/// (full-width or ASCII sentence enders beat commas); failing that, falls back to a hard cut with
/// an ellipsis. Pure string logic, unit-testable.
public func tightenPlanTitle(_ raw: String, maxLength: Int = 46) -> String {
    var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // Already the product of a hard cut (trailing ellipsis) → strip it and re-cut on punctuation,
    // so "…" doesn't stack
    while line.hasSuffix("…") || line.hasSuffix("...") {
        line = String(line.dropLast(line.hasSuffix("…") ? 1 : 3))
            .trimmingCharacters(in: .whitespaces)
    }
    let strong = Set<Character>("。！？；.!?;")
    let weak = Set<Character>("，,、")
    let head = Array(line.prefix(maxLength))
    // Sentence-ending punctuation: cut just before it (titles carry no period)
    if let index = head.lastIndex(where: { strong.contains($0) }), index > 0 {
        return String(head[0..<index]).trimmingCharacters(in: .whitespaces)
    }
    // Commas / enumeration commas: must leave a meaningful chunk; ones too close to the start don't
    // count
    if let index = head.lastIndex(where: { weak.contains($0) }), index >= 8 {
        return String(head[0..<index]).trimmingCharacters(in: .whitespaces)
    }
    if line.count > maxLength {
        return String(head).trimmingCharacters(in: .whitespaces) + "…"
    }
    return line
}
