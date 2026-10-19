import Foundation

/// A multiple-choice question the agent put to the user (Claude Code's AskUserQuestion), waiting to
/// be answered on the island. Written by the `lululumei-ask` hook to `<spool>/questions/<id>.json`;
/// the hook process blocks until it receives the answer.
public struct PendingQuestion: Equatable, Sendable, Identifiable {
    /// File name id (a UUID the hook generates for each wait)
    public var id: String
    public var source: AgentSource
    public var sessionId: String?
    public var cwd: String?
    /// Session transcript: when the user answers first in Claude's own confirmation UI, this is how
    /// we find the question was settled
    public var transcriptPath: String?
    /// The waiting hook process; if it's gone, Claude has abandoned this wait (timeout / user
    /// interrupted the turn)
    public var hookPid: Int32
    public var createdAt: Date
    public var questions: [AskQuestion]

    public init(
        id: String, source: AgentSource = .claude, sessionId: String? = nil, cwd: String? = nil,
        transcriptPath: String? = nil, hookPid: Int32, createdAt: Date, questions: [AskQuestion]
    ) {
        self.id = id
        self.source = source
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.hookPid = hookPid
        self.createdAt = createdAt
        self.questions = questions
    }

    /// Same scheme as TaskStore's task id; used to find the session title / terminal
    public var taskId: String? {
        sessionId.map { AgentTask.key(source: source, sessionId: $0) }
    }
}

public struct AskQuestion: Equatable, Sendable {
    /// The question text. Also the answer key: Claude matches answers by question text
    public var question: String
    /// Short label (Claude limits it to 12 characters); may be empty
    public var header: String
    public var options: [AskOption]
    public var multiSelect: Bool

    public init(question: String, header: String, options: [AskOption], multiSelect: Bool) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

public struct AskOption: Equatable, Sendable {
    public var label: String
    public var description: String

    public init(label: String, description: String = "") {
        self.label = label
        self.description = description
    }
}
