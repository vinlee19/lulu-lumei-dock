import Foundation

/// The "what it's doing" label on an island task row: tool name + the shortest useful object
/// string.
///
/// One island row must fit the title, this label, ctx% and the timer, so space is tight.
/// Hence an explicit budget for the object string instead of `truncationMode(.middle)` --
/// that squeezes `swift build -c release` into `s…release` (no information, and it squashes
/// the title too). If it doesn't fit, keep only the tool name: the full object is visible on
/// the "waiting for permission" card and the audit page, so this row needn't carry it all.
///
/// Paths keep their last component (`/repo/src/main.swift` → `main.swift`, the distinctive
/// part); commands are truncated from the **head** -- a slash in a command doesn't make it a
/// path (`rm -rf node_modules/`), and what you most need to see first in a command is the verb
/// and arguments (`rm -rf` is exactly the part to keep).
public func compactToolLabel(tool: String, detail: String?, budget: Int = 12) -> String {
    guard let detail, !detail.isEmpty else { return tool }
    let short: String
    if isPathLike(detail) {
        // The last component may be empty due to a trailing slash (`/a/b/` → take b)
        let parts = detail.split(separator: "/", omittingEmptySubsequences: true)
        short = parts.last.map(String.init) ?? detail
    } else {
        short = detail
    }
    guard short.count > budget else { return "\(tool) \(short)" }
    return "\(tool) \(short.prefix(budget))…"
}

/// Looks like a single file/directory path (rather than a command containing a path)
func isPathLike(_ text: String) -> Bool {
    guard !text.contains(" ") else { return false }  // a space means it's a command
    return text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./")
        || text.contains("/")
}

