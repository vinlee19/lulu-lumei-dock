import EurekaKit
import EurekaStore
import Foundation

/// 一条对话消息（Claude / Codex / opencode 三源统一模型，会话查看器用）
public struct TranscriptMessage: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case user
        case assistant
        case toolNote   // 工具调用小注（🔧 <名称>，opencode/grok/antigravity 用）
        case error      // API 错误等
        case turnTrail  // 一轮工具/检索轨迹聚合（Claude/Codex 产出，steps 承载明细）
    }

    /// 文件内序号（对话目录跳转锚点）
    public let id: Int
    public var role: Role
    /// turnTrail 的 text 是轨迹纯文本渲染（会话内搜索/导出兜底可命中）
    public var text: String
    public var timestamp: Date?
    /// 工具轨迹明细（仅 role == .turnTrail 非空）
    public var steps: [ToolStep]

    public init(
        id: Int, role: Role, text: String, timestamp: Date? = nil, steps: [ToolStep] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.steps = steps
    }
}

/// 会话对话记录读取器：整文件解析（容错跳过坏行），超上限截断。
public enum TranscriptReader {
    public struct Result: Equatable, Sendable {
        public var messages: [TranscriptMessage]
        public var truncated: Bool
    }

    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 统一入口：按 source 分派
    public static func load(
        session: AgentSessionInfo, maxMessages: Int = 2000
    ) -> Result {
        switch session.source {
        case .claude:
            return loadClaude(path: session.transcriptPath, maxMessages: maxMessages)
        case .codex:
            return loadCodex(path: session.transcriptPath, maxMessages: maxMessages)
        case .opencode:
            return loadOpencode(
                dbPath: session.transcriptPath, sessionId: session.id,
                maxMessages: maxMessages)
        case .grok:
            return loadGrok(path: session.transcriptPath, maxMessages: maxMessages)
        case .antigravity:
            return loadAntigravity()
        case .kimi:
            return loadKimi(path: session.transcriptPath, maxMessages: maxMessages)
        }
    }

    // MARK: - Antigravity（conversations/<uuid>.db，内容为私有二进制 protobuf）

    /// Antigravity 会话正文全在 protobuf blob 里（Google 未公开 schema），本项目零依赖无法解码。
    /// 返回一条说明小注，避免详情页空白误导。
    public static func loadAntigravity() -> Result {
        Result(
            messages: [TranscriptMessage(
                id: 0, role: .toolNote,
                text: "🔒 Antigravity 对话为私有二进制（protobuf）格式，暂不支持正文预览")],
            truncated: false)
    }

    // MARK: - Claude（~/.claude/projects/<encoded>/<session>.jsonl）

    public static func loadClaude(path: String, maxMessages: Int) -> Result {
        var messages: [TranscriptMessage] = []
        var truncated = false
        // 每轮工具轨迹：懒创建在该轮第一个 tool_use 出现的位置，后续步骤原地追加
        var trailIndex: Int?
        // tool_use_id → 步骤位置（tool_result is_error 回填用）
        var stepAt: [String: (msg: Int, step: Int)] = [:]
        // 步数计入截断预算（近似旧口径：旧版每个 tool_use 占一条 toolNote，新版每轮多计 1 条 trail 容器）
        var stepCount = 0
        func withinBudget() -> Bool { messages.count + stepCount < maxMessages }

        forEachJSONLine(path: path) { root in
            guard withinBudget() else {
                truncated = true
                return false
            }
            let type = root["type"] as? String
            let timestamp = (root["timestamp"] as? String).flatMap(parseTimestamp)
            switch type {
            case "user":
                guard root["isMeta"] as? Bool != true,
                      let message = root["message"] as? [String: Any]
                else { return true }
                if let content = message["content"] as? String {
                    // 真实用户提问 = 新一轮
                    trailIndex = nil
                    messages.append(TranscriptMessage(
                        id: messages.count, role: .user, text: content, timestamp: timestamp))
                } else if let blocks = message["content"] as? [[String: Any]] {
                    // 数组 = tool_result：不入正文，仅按 tool_use_id 回填失败标记
                    for block in blocks where block["type"] as? String == "tool_result" {
                        guard block["is_error"] as? Bool == true,
                              let toolUseId = block["tool_use_id"] as? String,
                              let pos = stepAt[toolUseId]
                        else { continue }
                        messages[pos.msg].steps[pos.step].isError = true
                    }
                }
            case "assistant":
                guard root["isSidechain"] as? Bool != true,
                      let message = root["message"] as? [String: Any]
                else { return true }
                let isError = root["isApiErrorMessage"] as? Bool == true
                    || message["model"] as? String == "<synthetic>"
                guard let blocks = message["content"] as? [[String: Any]] else { return true }
                for block in blocks {
                    guard withinBudget() else {
                        truncated = true
                        return false
                    }
                    switch block["type"] as? String {
                    case "text":
                        guard let text = block["text"] as? String,
                              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else { continue }
                        messages.append(TranscriptMessage(
                            id: messages.count, role: isError ? .error : .assistant,
                            text: text, timestamp: timestamp))
                    case "tool_use":
                        let name = block["name"] as? String ?? "工具"
                        let step = ToolStepExtractor.claude(
                            name: name, input: block["input"] as? [String: Any])
                        if trailIndex == nil {
                            messages.append(TranscriptMessage(
                                id: messages.count, role: .turnTrail, text: "",
                                timestamp: timestamp))
                            trailIndex = messages.count - 1
                        }
                        messages[trailIndex!].steps.append(step)
                        if let toolUseId = block["id"] as? String {
                            stepAt[toolUseId] =
                                (trailIndex!, messages[trailIndex!].steps.count - 1)
                        }
                        stepCount += 1
                    default:
                        break  // thinking 明文落盘时已被剥离（只剩加密 signature），无可展示
                    }
                }
            default:
                break  // ai-title / system / summary 等跳过
            }
            return true
        }
        backfillTrailText(&messages)
        return Result(messages: messages, truncated: truncated)
    }

    // MARK: - Codex（~/.codex/sessions/.../rollout-*.jsonl）

    /// 正文用 event_msg（user_message / agent_message 纯字符串）；
    /// 工具轨迹用 response_item（function_call / web_search_call）+ event_msg 的 mcp_tool_call_end。
    /// reasoning 新版已加密，无明文可展示。
    public static func loadCodex(path: String, maxMessages: Int) -> Result {
        var messages: [TranscriptMessage] = []
        var truncated = false
        var trailIndex: Int?
        // call_id → 步骤位置（function_call_output exit_code 回填用）
        var stepAt: [String: (msg: Int, step: Int)] = [:]
        var stepCount = 0
        func withinBudget() -> Bool { messages.count + stepCount < maxMessages }
        func appendStep(_ step: ToolStep, callId: String?, timestamp: Date?) {
            if trailIndex == nil {
                messages.append(TranscriptMessage(
                    id: messages.count, role: .turnTrail, text: "", timestamp: timestamp))
                trailIndex = messages.count - 1
            }
            messages[trailIndex!].steps.append(step)
            if let callId {
                stepAt[callId] = (trailIndex!, messages[trailIndex!].steps.count - 1)
            }
            stepCount += 1
        }

        forEachJSONLine(path: path) { root in
            guard withinBudget() else {
                truncated = true
                return false
            }
            guard let payload = root["payload"] as? [String: Any] else { return true }
            let timestamp = (root["timestamp"] as? String).flatMap(parseTimestamp)
            switch root["type"] as? String {
            case "event_msg":
                switch payload["type"] as? String {
                case "user_message":
                    if let text = payload["message"] as? String, !text.isEmpty {
                        trailIndex = nil  // 用户消息 = 新一轮
                        messages.append(TranscriptMessage(
                            id: messages.count, role: .user, text: text, timestamp: timestamp))
                    }
                case "agent_message":
                    if let text = payload["message"] as? String, !text.isEmpty {
                        messages.append(TranscriptMessage(
                            id: messages.count, role: .assistant, text: text,
                            timestamp: timestamp))
                    }
                case "error":
                    if let text = payload["message"] as? String, !text.isEmpty {
                        messages.append(TranscriptMessage(
                            id: messages.count, role: .error, text: text, timestamp: timestamp))
                    }
                case "mcp_tool_call_end":
                    // MCP 干净命名在这里（function_call 里是 "_" 前缀的重复项）；result.Err 判错
                    let invocation = payload["invocation"] as? [String: Any]
                    let server = invocation?["server"] as? String ?? "mcp"
                    let tool = invocation?["tool"] as? String ?? "?"
                    let isError = (payload["result"] as? [String: Any])?["Err"] != nil
                    appendStep(
                        ToolStep(
                            kind: .mcp, name: "\(server).\(tool)",
                            detail: ToolStepExtractor.clip(ToolStepExtractor.firstString(
                                in: invocation?["arguments"] as? [String: Any])),
                            isError: isError),
                        callId: nil, timestamp: timestamp)
                default:
                    break
                }
            case "response_item":
                switch payload["type"] as? String {
                case "function_call":
                    // "_" 前缀 = MCP 重复项，跳过（同 CodexUsageScanner 口径）
                    guard let name = payload["name"] as? String, !name.isEmpty,
                          !name.hasPrefix("_")
                    else { return true }
                    appendStep(
                        ToolStepExtractor.codex(
                            name: name, argumentsJSON: payload["arguments"] as? String),
                        callId: payload["call_id"] as? String, timestamp: timestamp)
                case "function_call_output":
                    // 可选增强：exit_code != 0 回填失败标记（嵌套 JSON，失败静默跳过）
                    guard let callId = payload["call_id"] as? String,
                          let pos = stepAt[callId],
                          let output = payload["output"] as? String,
                          let parsed = (try? JSONSerialization.jsonObject(
                            with: Data(output.utf8))) as? [String: Any],
                          let metadata = parsed["metadata"] as? [String: Any],
                          let exitCode = metadata["exit_code"] as? Int, exitCode != 0
                    else { return true }
                    messages[pos.msg].steps[pos.step].isError = true
                case "web_search_call":
                    let action = payload["action"] as? [String: Any]
                    appendStep(
                        ToolStep(
                            kind: .web, name: "web_search",
                            detail: ToolStepExtractor.clip(action?["query"] as? String)),
                        callId: nil, timestamp: timestamp)
                default:
                    break  // reasoning（加密）/ message（与 event_msg 重复）等跳过
                }
            default:
                break  // session_meta / turn_context 等跳过
            }
            return true
        }
        backfillTrailText(&messages)
        return Result(messages: messages, truncated: truncated)
    }

    /// 收尾：turnTrail 消息回填纯文本渲染（搜索/导出兜底）
    private static func backfillTrailText(_ messages: inout [TranscriptMessage]) {
        for index in messages.indices where messages[index].role == .turnTrail {
            messages[index].text = ToolStepExtractor.plainText(messages[index].steps)
        }
    }

    // MARK: - opencode（opencode.db 只读：message 表 role + part 表正文）

    public static func loadOpencode(dbPath: String, sessionId: String, maxMessages: Int) -> Result {
        guard let db = try? SQLiteDB(path: dbPath, readOnly: true) else {
            return Result(messages: [], truncated: false)
        }
        var messages: [TranscriptMessage] = []
        var truncated = false
        // 消息按创建时间排序；role 在 message.data JSON 里
        let rows = (try? db.query("""
        SELECT id, data, time_created FROM message
        WHERE session_id = ? ORDER BY time_created, id
        """, [.text(sessionId)]) { row -> (String, String, Double) in
            (row.text(0) ?? "", row.text(1) ?? "{}", row.real(2))
        }) ?? []

        for (messageId, dataJSON, createdMs) in rows {
            if messages.count >= maxMessages {
                truncated = true
                break
            }
            let info = (try? JSONSerialization.jsonObject(
                with: Data(dataJSON.utf8))) as? [String: Any] ?? [:]
            let role: TranscriptMessage.Role =
                (info["role"] as? String) == "user" ? .user : .assistant
            let timestamp = Date(timeIntervalSince1970: createdMs / 1000)

            // 正文 = 该消息全部 text part 拼接；tool part 记小注
            let parts = (try? db.query(
                "SELECT data FROM part WHERE message_id = ? ORDER BY id",
                [.text(messageId)]) { $0.text(0) ?? "{}" }) ?? []
            var textPieces: [String] = []
            var toolNames: [String] = []
            for partJSON in parts {
                guard let part = (try? JSONSerialization.jsonObject(
                    with: Data(partJSON.utf8))) as? [String: Any] else { continue }
                switch part["type"] as? String {
                case "text":
                    if let text = part["text"] as? String, !text.isEmpty {
                        textPieces.append(text)
                    }
                case "tool":
                    toolNames.append(part["tool"] as? String ?? "工具")
                default:
                    break  // reasoning / step-start 等跳过
                }
            }
            for tool in toolNames {
                guard messages.count < maxMessages else { break }
                messages.append(TranscriptMessage(
                    id: messages.count, role: .toolNote,
                    text: "🔧 \(tool)", timestamp: timestamp))
            }
            let text = textPieces.joined(separator: "\n")
            if !text.isEmpty && messages.count < maxMessages {
                messages.append(TranscriptMessage(
                    id: messages.count, role: role, text: text, timestamp: timestamp))
            }
        }
        return Result(messages: messages, truncated: truncated)
    }

    // MARK: - grok（~/.grok/sessions/<enc>/<uuid>/chat_history.jsonl）

    /// user 的 content 是 [{type:text,text}] 数组；assistant 的 content 是纯字符串。
    /// reasoning（加密）/ tool_result（冗长）/ backend_tool_call / system 一律跳过。
    /// chat_history.jsonl 无逐条时间戳 → 用同目录 events.jsonl 的 turn_started 时间按轮次补：
    /// 每条真实用户提问推进一轮，该轮内所有消息共用该轮开始时间（轮次粒度）。
    public static func loadGrok(path: String, maxMessages: Int) -> Result {
        let eventsPath = URL(fileURLWithPath: path)
            .deletingLastPathComponent().appendingPathComponent("events.jsonl").path
        let turnTimes = grokTurnTimes(eventsPath: eventsPath)
        var turnIndex = -1
        var currentTime: Date? = turnTimes.first

        var messages: [TranscriptMessage] = []
        var truncated = false
        forEachJSONLine(path: path) { root in
            guard messages.count < maxMessages else {
                truncated = true
                return false
            }
            switch root["type"] as? String {
            case "user":
                // 真实提问（无 synthetic_reason，synthetic 是工具续跑）推进一轮时间
                if root["synthetic_reason"] == nil, !turnTimes.isEmpty {
                    turnIndex += 1
                    currentTime = turnTimes[min(turnIndex, turnTimes.count - 1)]
                }
                guard let blocks = root["content"] as? [[String: Any]] else { return true }
                let text = blocks
                    .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    messages.append(TranscriptMessage(
                        id: messages.count, role: .user, text: text, timestamp: currentTime))
                }
            case "assistant":
                guard let text = (root["content"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
                else { return true }
                messages.append(TranscriptMessage(
                    id: messages.count, role: .assistant, text: text, timestamp: currentTime))
            default:
                break
            }
            return true
        }
        return Result(messages: messages, truncated: truncated)
    }

    // MARK: - kimi（~/.kimi-code/sessions/<ws>/<session>/agents/main/wire.jsonl）

    /// wire.jsonl 为事件溯源日志（epoch-ms `time`，schema 已对真实会话核验）：
    /// user 正文 = turn.prompt(origin=user) 的 input text 块；
    /// assistant 正文 = loop 事件 content.part(part.type=text) 整段（think 段跳过）；
    /// tool.call 记 🔧 小注；metadata/config/usage 等跳过。
    public static func loadKimi(path: String, maxMessages: Int) -> Result {
        var messages: [TranscriptMessage] = []
        var truncated = false

        forEachJSONLine(path: path) { root in
            guard messages.count < maxMessages else {
                truncated = true
                return false
            }
            let timestamp = KimiWireDecoder.timestamp(root)
            if let prompt = KimiWireDecoder.promptText(root) {
                messages.append(TranscriptMessage(
                    id: messages.count, role: .user, text: prompt, timestamp: timestamp))
            } else if let text = KimiWireDecoder.assistantText(root) {
                messages.append(TranscriptMessage(
                    id: messages.count, role: .assistant, text: text, timestamp: timestamp))
            } else if let call = KimiWireDecoder.toolCall(root) {
                messages.append(TranscriptMessage(
                    id: messages.count, role: .toolNote,
                    text: "🔧 \(call.name)", timestamp: timestamp))
            }
            return true
        }
        return Result(messages: messages, truncated: truncated)
    }

    /// 同目录 events.jsonl 按顺序的 turn_started 时间（grok 对话按轮次补时间用）
    private static func grokTurnTimes(eventsPath: String) -> [Date] {
        var times: [Date] = []
        forEachJSONLine(path: eventsPath) { root in
            if root["type"] as? String == "turn_started",
               let ts = (root["ts"] as? String).flatMap(parseTimestamp) {
                times.append(ts)
            }
            return true
        }
        return times
    }

    // MARK: - 工具

    /// 逐行解析 jsonl（坏行/半行容错跳过）；body 返回 false 提前终止
    private static func forEachJSONLine(
        path: String, _ body: ([String: Any]) -> Bool
    ) {
        guard let data = FileManager.default.contents(atPath: path) else { return }
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let lineData = data[start..<end]
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
            guard !lineData.isEmpty,
                  let root = (try? JSONSerialization.jsonObject(
                    with: Data(lineData))) as? [String: Any]
            else { continue }
            if !body(root) { return }
        }
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        iso8601.date(from: raw) ?? ClaudeSessionFirstTimestamp.parse(raw)
    }
}

/// 把对话记录渲染为 Markdown（会话导出/复制用）。纯函数，可单测。
public enum TranscriptMarkdown {
    public static func render(session: AgentSessionInfo, messages: [TranscriptMessage]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines: [String] = ["# \(session.name ?? "会话 \(session.id)")", ""]
        lines.append("- 来源：\(session.source.displayName)")
        if let cwd = session.cwd { lines.append("- 项目：\(cwd)") }
        lines.append("- 会话 ID：\(session.id)")
        lines.append("")
        for message in messages {
            let time = message.timestamp.map { " (\(formatter.string(from: $0)))" } ?? ""
            switch message.role {
            case .user:
                lines.append("## 用户\(time)"); lines.append(""); lines.append(message.text)
            case .assistant:
                lines.append("## 助手\(time)"); lines.append(""); lines.append(message.text)
            case .error:
                lines.append("## 错误\(time)"); lines.append(""); lines.append(message.text)
            case .toolNote:
                lines.append("- \(message.text)")
            case .turnTrail:
                lines.append("- 🛠 本轮轨迹（\(message.steps.count) 步）")
                for step in message.steps {
                    let flag = step.isError ? "（失败）" : ""
                    let detail = step.detail.isEmpty ? "" : "：\(step.detail)"
                    lines.append("  - [\(step.kind.label)] \(step.name)\(flag)\(detail)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// 文件名安全化（去掉路径分隔符等）
    public static func safeFileName(_ name: String) -> String {
        String(name.map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 }).prefix(80).description
    }
}
