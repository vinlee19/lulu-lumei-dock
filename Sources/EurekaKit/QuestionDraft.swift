import Foundation

/// 灵动岛上一张提问卡的作答进度：多个问题逐个回答，全部答完才交给 hook。
///
/// 答案的格式照 AskUserQuestion 的约定：键是问题原文；单选是选项 label；
/// 多选是选中 label 按选项顺序用「, 」连接；自由输入是用户打的文字（多选时接在已选项后面）。
/// 纯逻辑；视图与 IslandViewModel 只调用这里的操作。
public struct QuestionDraft: Equatable, Sendable {
    public let question: PendingQuestion
    /// 当前在答第几个问题
    public private(set) var index = 0
    public private(set) var answers: [String: String] = [:]
    /// 当前多选题已勾选的 label
    public private(set) var selected: Set<String> = []
    /// 正在输入「其他」
    public private(set) var isTypingOther = false

    public init(question: PendingQuestion) {
        self.question = question
    }

    public var current: AskQuestion { question.questions[index] }
    public var progress: (current: Int, total: Int) { (index + 1, question.questions.count) }
    /// 所有问题都有答案：可以交给 hook 了
    public var isComplete: Bool {
        question.questions.allSatisfy { !(answers[$0.question] ?? "").isEmpty }
    }

    /// 单选题点了某个选项：记下答案并进入下一题
    public mutating func choose(_ label: String) {
        guard !current.multiSelect, current.options.contains(where: { $0.label == label }) else {
            return
        }
        record(label)
    }

    /// 多选题勾选 / 取消
    public mutating func toggle(_ label: String) {
        guard current.multiSelect, current.options.contains(where: { $0.label == label }) else {
            return
        }
        if selected.contains(label) {
            selected.remove(label)
        } else {
            selected.insert(label)
        }
    }

    /// 多选题点「确定」：至少勾了一个才算数
    public mutating func confirmSelection() {
        guard current.multiSelect, !selected.isEmpty else { return }
        record(selectedLabelsInOrder.joined(separator: ", "))
    }

    public mutating func beginOther() {
        isTypingOther = true
    }

    public mutating func cancelOther() {
        isTypingOther = false
    }

    /// 提交「其他」输入的文字；空白不算
    public mutating func submitOther(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parts = current.multiSelect ? selectedLabelsInOrder + [trimmed] : [trimmed]
        record(parts.joined(separator: ", "))
    }

    private var selectedLabelsInOrder: [String] {
        current.options.map(\.label).filter { selected.contains($0) }
    }

    private mutating func record(_ answer: String) {
        answers[current.question] = answer
        selected = []
        isTypingOther = false
        if index + 1 < question.questions.count { index += 1 }
    }
}
