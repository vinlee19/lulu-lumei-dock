import Foundation

/// 计划完成度解析：从计划正文数任务清单标记（`- [x]` / `- [~]` / `- [ ]`），
/// 以及提取一句话摘要。纯字符串逻辑、无 IO，便于单测。
/// 兼容列表前缀 `-` / `*` / `+` / `1.` / `2)`，方框内 `x`/`X`=完成、`~`/`/`=进行中、其余=未开始。
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

        /// 完成占比（无清单项 → nil，用于判定「是否有进度可展示」）
        public var fraction: Double? {
            total > 0 ? Double(done) / Double(total) : nil
        }
    }

    /// 逐行统计任务清单项。
    public static func checklist(_ markdown: String) -> Checklist {
        var done = 0, inProgress = 0, total = 0
        markdown.enumerateLines { line, _ in
            guard let mark = checkboxMark(line.trimmingCharacters(in: .whitespaces)) else { return }
            total += 1
            switch mark {
            case "x", "X": done += 1
            case "~", "/": inProgress += 1
            default: break
            }
        }
        return Checklist(done: done, inProgress: inProgress, total: total)
    }

    /// 一句话摘要：首个「非标题(#) / 非引用(>) / 非分隔线 / 非代码围栏 / 非表格 / 非清单项 / 非空」的正文行，
    /// 去掉常见 markdown 修饰符后返回（截断交给视图）。
    public static func summary(_ markdown: String) -> String? {
        var found: String?
        markdown.enumerateLines { line, stop in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix(">") { return }
            if t.hasPrefix("---") || t.hasPrefix("```") || t.hasPrefix("|") { return }
            if checkboxMark(t) != nil { return }
            let cleaned = t
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*+• "))
            if !cleaned.isEmpty {
                found = cleaned
                stop = true
            }
        }
        return found
    }

    /// 匹配 `- [x] …` / `* [ ] …` / `1. [~] …`，返回方框内字符；非清单行返回 nil。
    /// 入参需为已去首部空白的行。
    private static func checkboxMark(_ trimmed: String) -> Character? {
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
        return mark
    }
}
