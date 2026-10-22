import Foundation

/// Plan progress parsing: counts task checklist markers (`- [x]` / `- [~]` / `- [ ]`) in the plan
/// body and extracts a one-line summary. Pure string logic, no IO, easy to unit test.
/// Accepts list prefixes `-` / `*` / `+` / `1.` / `2)`; inside the box `x`/`X` = done,
/// `~`/`/` = in progress, anything else = not started.
public enum PlanParsing {
    public struct Checklist: Equatable, Sendable {
        public let done: Int
        public let inProgress: Int
        public let total: Int

        public init(done: Int, inProgress: Int, total: Int) {
            self.done = done
            self.inProgress = inProgress
            self.total = total
        }

        /// Completed fraction (no checklist items → nil, used to decide whether there is progress
        /// to show)
        public var fraction: Double? {
            total > 0 ? Double(done) / Double(total) : nil
        }
    }

    /// Counts task checklist items line by line.
    public static func checklist(_ markdown: String) -> Checklist {
        var done = 0, inProgress = 0, total = 0
        markdown.enumerateLines { line, _ in
            guard let item = checkbox(line.trimmingCharacters(in: .whitespaces)) else { return }
            total += 1
            switch item.mark {
            case "x", "X": done += 1
            case "~", "/": inProgress += 1
            default: break
            }
        }
        return Checklist(done: done, inProgress: inProgress, total: total)
    }

    /// Text of the first task checklist item (list marker and box removed). Plans with a
    /// placeholder title (such as the zhHans "Codex plan" title) are named after it instead — that
    /// is the first thing the plan actually sets out to do.
    public static func firstStep(_ markdown: String) -> String? {
        var found: String?
        markdown.enumerateLines { line, stop in
            guard let item = checkbox(line.trimmingCharacters(in: .whitespaces)),
                  !item.text.isEmpty else { return }
            found = item.text
            stop = true
        }
        return found
    }

    /// One-line summary: the first body line that is not a heading (#) / quote (>) / divider / code
    /// fence / table / checklist item / blank, returned with common markdown decorations stripped
    /// (truncation is left to the view). When a lead-in line ends with a colon, the following
    /// content line is appended so the summary does not stop on an incomplete intro.
    public static func summary(_ markdown: String) -> String? {
        var found: String?
        var pendingIntro: String?
        markdown.enumerateLines { line, stop in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix(">") { return }
            if t.hasPrefix("---") || t.hasPrefix("```") || t.hasPrefix("|") { return }
            if let item = checkbox(t) {
                if let intro = pendingIntro, !item.text.isEmpty {
                    found = "\(intro) \(item.text)"
                    stop = true
                }
                return
            }
            let cleaned = t
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*+• "))
            guard !cleaned.isEmpty else { return }
            if let intro = pendingIntro {
                found = "\(intro) \(cleaned)"
                stop = true
            } else if (cleaned.hasSuffix(":") || cleaned.hasSuffix("：")) && cleaned.count < 48 {
                pendingIntro = cleaned
            } else {
                found = cleaned
                stop = true
            }
        }
        return found ?? pendingIntro
    }

    /// Matches `- [x] …` / `* [ ] …` / `1. [~] …` and returns the box character and the step text
    /// after it; returns nil for non-checklist lines. The input must already have leading
    /// whitespace trimmed.
    private static func checkbox(_ trimmed: String) -> (mark: Character, text: String)? {
        var s = Substring(trimmed)
        if let first = s.first, first == "-" || first == "*" || first == "+" {
            s = s.dropFirst()
        } else {
            let digits = s.prefix(while: { $0.isNumber })
            guard !digits.isEmpty else { return nil }
            let rest = s.dropFirst(digits.count)
            guard let sep = rest.first, sep == "." || sep == ")" else { return nil }
            s = rest.dropFirst()
        }
        guard s.first == " " else { return nil }
        s = s.drop(while: { $0 == " " })
        guard s.first == "[" else { return nil }
        s = s.dropFirst()
        guard let mark = s.first else { return nil }
        s = s.dropFirst()
        guard s.first == "]" else { return nil }
        let text = s.dropFirst()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        return (mark, text)
    }
}
