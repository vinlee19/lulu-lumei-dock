import Foundation

/// 轮后纠偏信号：一条 prompt 发出后，用户下一条提问透露的满意度（评价体系里
/// 最强的结果信号，文献线见 docs/research/2026-08-24-prompt-evaluation-methods.md §5d/§7）。
///
/// 两个独立判定：
/// - `isCorrective`：下一条提问是否是**纠偏**（"不对/重来/理解错"）——直接失败标注
///   （20,574 会话研究把 developer pushback 用作 misalignment 的操作化定义）。
/// - `reformulation`：下一条是否是对上一条的**重述**，并按 Hassan（WSDM 2014）的
///   词汇转移特征消歧——**替换主导 = 挣扎**（换词绕同一目标打转，记负）、
///   **新增主导 = 探索**（加面向展开，正常工作方式，不记负）。
public enum PromptFollowupSignal {
    public enum Reformulation: Int, Sendable {
        case none = 0
        case struggle = 1
        case explore = 2
    }

    /// 纠偏词表：显式否定/回退措辞。用复合短语控误报（"重新"单独出现常是
    /// 正常新指令，"重新来/重来"才是纠偏）。只查前缀 120 字符——纠偏话通常开门见山。
    static let correctiveLexicon = [
        "不对", "不是这", "不是我要", "不是我想", "重来", "重新来", "重新做", "重新写",
        "搞错", "弄错", "理解错", "领会错", "还是有问题", "还是不行", "还是不对",
        // "回退"裸词会误伤领域内容（"越界回退语义"），只收带指向的形态
        "没有生效", "没生效", "并没有", "错了", "撤销", "回退刚才", "回退到", "回滚", "别这样",
        "revert", "undo", "that's wrong", "that is wrong", "not what i",
        "still broken", "still fails", "didn't work", "doesn't work",
    ]

    public static func isCorrective(_ next: String) -> Bool {
        let head = String(next.prefix(120)).lowercased()
        return correctiveLexicon.contains { head.contains($0) }
    }

    /// 相邻提问的重述判定 + 挣扎/探索消歧。
    ///
    /// 重述判定用 **overlap coefficient**（|∩|/min(|A|,|B|)≥0.5）而非 Jaccard——
    /// 探索型扩写会把 Jaccard 稀释到阈值之下（原话 8 token + 新增 13 token 时
    /// Jaccard 只剩 0.38），而 overlap 对"包含原话的展开"恒高。<4 token 超短句不判。
    ///
    /// 消歧判据：**prev 几乎全保留（removed ≤ 1）且净增新词 = 探索**（在原话上
    /// 加约束展开，正常工作方式）；其余重述（换词、逐字重发、缩短重试）= 挣扎。
    /// 之前的"removed ≥ added"判据会被纠偏前缀带进来的新 token 干扰
    /// （"不对，把 X 换成 Y" 的 added 被"不对"抬高而误判成探索）。
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

    /// 分词：CJK 逐字 bigram（无空格语言的相似度基元）+ 拉丁/数字按词小写。
    /// 只取前 512 字符——重述判定看的是主旨，不需要全文。public 供测试直接断言分词行为。
    public static func tokens(_ text: String) -> Set<String> {
        var result = Set<String>()
        var latinRun = ""
        var previousCJK: Character?
        for char in text.prefix(512) {
            if char.isLetter && !char.isASCII {
                // CJK（及其它非 ASCII 字母）：与前一个 CJK 字符组成 bigram
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
