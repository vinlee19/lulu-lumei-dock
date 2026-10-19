import Foundation

/// agent 抛给用户的选择题（Claude Code 的 AskUserQuestion），正等着在灵动岛上回答。
/// 由 `lululumei-ask` hook 写入 `<spool>/questions/<id>.json`，hook 进程挂起直到收到答案。
public struct PendingQuestion: Equatable, Sendable, Identifiable {
    /// 文件名 id（来自 tool_use_id，已清洗成只含字母数字 `-` `_`）
    public var id: String
    public var source: AgentSource
    public var sessionId: String?
    public var cwd: String?
    /// 等待中的 hook 进程；它不在了说明 Claude 已经放弃这次等待（超时 / 终端里中断）
    public var hookPid: Int32
    public var createdAt: Date
    public var questions: [AskQuestion]

    public init(
        id: String, source: AgentSource = .claude, sessionId: String? = nil, cwd: String? = nil,
        hookPid: Int32, createdAt: Date, questions: [AskQuestion]
    ) {
        self.id = id
        self.source = source
        self.sessionId = sessionId
        self.cwd = cwd
        self.hookPid = hookPid
        self.createdAt = createdAt
        self.questions = questions
    }

    /// 与 TaskStore 的任务 id 同口径，用来找会话标题 / 终端
    public var taskId: String? {
        sessionId.map { AgentTask.key(source: source, sessionId: $0) }
    }
}

public struct AskQuestion: Equatable, Sendable {
    /// 问题原文。也是回答的键：Claude 按问题原文对答案
    public var question: String
    /// 短标签（Claude 限 12 字符），可能为空
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
