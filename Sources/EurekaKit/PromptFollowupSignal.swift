import Foundation

/// Post-turn correction signal: the satisfaction revealed by the user's next prompt after one is
/// sent (the strongest outcome signal in the evaluation scheme; literature in
/// docs/research/2026-08-24-prompt-evaluation-methods.md §5d/§7).
///
/// Two independent checks:
/// - `isCorrective`: whether the next prompt is a **correction** ("wrong" / "start over" /
///   "misunderstood"): a direct failure label (the 20,574-session study uses developer pushback as
///   its operational definition of misalignment).
/// - `reformulation`: whether the next prompt **restates** the previous one, disambiguated by
///   Hassan's (WSDM 2014) lexical-shift features: **substitution-dominant = struggling** (rewording
///   around the same goal, scored negative), **addition-dominant = exploring** (adding facets, a
///   normal way of working, not scored negative).
public enum PromptFollowupSignal {
    public enum Reformulation: Int, Sendable {
        case none = 0
        case struggle = 1
        case explore = 2
    }

    /// Correction phrases: explicit negation/rollback wording. Compound phrases keep false
    /// positives down (the word for "again" alone is often a normal new instruction; only "redo /
    /// start over" is a correction). Only the first 120 chars are checked; corrections usually
    /// lead.
    static let correctiveLexicon = [
        "不对", "不是这", "不是我要", "不是我想", "重来", "重新来", "重新做", "重新写",
        "搞错", "弄错", "理解错", "领会错", "还是有问题", "还是不行", "还是不对",
        // the bare word for "roll back" misfires on domain content (e.g. "out-of-bounds fallback
        // semantics"); only directed forms are listed
        "没有生效", "没生效", "并没有", "错了", "撤销", "回退刚才", "回退到", "回滚", "别这样",
        "revert", "undo", "that's wrong", "that is wrong", "not what i",
        "still broken", "still fails", "didn't work", "doesn't work",
    ]

    public static func isCorrective(_ next: String) -> Bool {
        let head = String(next.prefix(120)).lowercased()
        return correctiveLexicon.contains { head.contains($0) }
    }

    /// Restatement check between adjacent prompts + struggling/exploring disambiguation.
    ///
    /// Restatement uses the **overlap coefficient** (|∩|/min(|A|,|B|) ≥ 0.5) rather than Jaccard:
    /// exploratory expansion dilutes Jaccard below the threshold (original 8 tokens + 13 new tokens
    /// leaves Jaccard at 0.38), while overlap stays high for "an expansion that contains the
    /// original". Sentences under 4 tokens are not judged.
    ///
    /// Disambiguation rule: **prev almost fully kept (removed ≤ 1) with net new words = exploring**
    /// (adding constraints on top of the original, a normal way of working); every other
    /// restatement (rewording, verbatim resend, shortened retry) = struggling. The earlier "removed
    /// ≥ added" rule was skewed by new tokens a correction prefix brings in ("wrong, swap X for Y"
    /// had its added count inflated by "wrong" and was misjudged as exploring).
    public static func reformulation(prev: String, next: String) -> Reformulation {
        let prevTokens = tokens(prev)
        let nextTokens = tokens(next)
        guard prevTokens.count >= 4, nextTokens.count >= 4 else { return .none }
        let intersection = prevTokens.intersection(nextTokens).count
        let smaller = min(prevTokens.count, nextTokens.count)
        guard smaller > 0, Double(intersection) / Double(smaller) >= 0.5 else { return .none }
        let removed = prevTokens.subtracting(nextTokens).count
        let added = nextTokens.subtracting(prevTokens).count
        return (removed <= 1 && added > removed) ? .explore : .struggle
    }

    /// Tokenization: CJK as per-character bigrams (the similarity unit for unspaced languages) +
    /// Latin/digits as lowercase words. Only the first 512 chars: restatement is about the gist,
    /// not the full text. Public so tests can assert tokenization directly.
    public static func tokens(_ text: String) -> Set<String> {
        var result = Set<String>()
        var latinRun = ""
        var previousCJK: Character?
        for char in text.prefix(512) {
            if char.isLetter && !char.isASCII {
                // CJK (and other non-ASCII letters): form a bigram with the previous CJK character
                if !latinRun.isEmpty {
                    result.insert(latinRun.lowercased())
                    latinRun = ""
                }
                if let previous = previousCJK {
                    result.insert("\(previous)\(char)")
                }
                previousCJK = char
            } else if char.isLetter || char.isNumber {
                latinRun.append(char)
                previousCJK = nil
            } else {
                if !latinRun.isEmpty {
                    result.insert(latinRun.lowercased())
                    latinRun = ""
                }
                previousCJK = nil
            }
        }
        if !latinRun.isEmpty { result.insert(latinRun.lowercased()) }
        return result
    }
}
