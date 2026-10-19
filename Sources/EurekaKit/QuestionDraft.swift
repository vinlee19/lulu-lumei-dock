import Foundation

/// Answer progress of one question card on the island: multiple questions are answered one by one
/// and handed to the hook only when all are answered.
///
/// Answers follow AskUserQuestion's convention: keys are the question text; single-select is the
/// option label; multi-select is the checked labels joined with ", " in option order; free-form
/// input is the user's text (appended after the checked options for multi-select). Pure logic; the
/// view and IslandViewModel only call the operations here.
public struct QuestionDraft: Equatable, Sendable {
    public let question: PendingQuestion
    /// Index of the question currently being answered
    public private(set) var index = 0
    public private(set) var answers: [String: String] = [:]
    /// Labels checked so far in the current multi-select question
    public private(set) var selected: Set<String> = []
    /// Typing "Other"
    public private(set) var isTypingOther = false

    public init(question: PendingQuestion) {
        self.question = question
    }

    public var current: AskQuestion { question.questions[index] }
    public var progress: (current: Int, total: Int) { (index + 1, question.questions.count) }
    /// Every question has an answer: ready to hand to the hook
    public var isComplete: Bool {
        question.questions.allSatisfy { !(answers[$0.question] ?? "").isEmpty }
    }

    /// An option was clicked in a single-select question: record the answer and move to the next
    /// question
    public mutating func choose(_ label: String) {
        guard !current.multiSelect, current.options.contains(where: { $0.label == label }) else {
            return
        }
        record(label)
    }

    /// Multi-select check / uncheck
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

    /// "Confirm" clicked in a multi-select question: counts only if at least one is checked
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

    /// Submit the text typed into "Other"; whitespace-only doesn't count
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
