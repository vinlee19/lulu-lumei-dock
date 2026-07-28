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
        /// 模型思考正文。**只有部分源有**（Codex `agent_reasoning` / Kimi `think` /
        /// Qwen `thought`）；Claude 的 `thinking` 块落盘时正文已被剥离，只剩加密签名，
        /// 所以 Claude 永远不产出这个 role。
        case thinking
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
        case .gemini:
            return loadGemini(path: session.transcriptPath, maxMessages: maxMessages)
        case .qwen:
            return loadQwen(path: session.transcriptPath, maxMessages: maxMessages)
        case .hermes:
            return loadHermes(
                dbPath: session.transcriptPath, sessionId: session.id,
                maxMessages: maxMessages)
        case .codebuddy:
            return loadCodeBuddy(path: session.transcriptPath, maxMessages: maxMessages)
        case .qoder:
            return loadQoder(path: session.transcriptPath, maxMessages: maxMessages)
        case .cursor:
            return loadCursor(
                dbPath: session.transcriptPath, composerId: session.id,
                maxMessages: maxMessages)
        }
    }

    // MARK: - Cursor（state.vscdb 只读：composerData 给气泡顺序，bubbleId 行给正文）

    /// 消息顺序取 `composerData.fullConversationHeadersOnly`（气泡在 KV 里是散的，
    /// key 按 uuid 排序，只有这张表知道时序）。`type` 1=user / 2=assistant；
    /// `toolFormerData` 记 🔧 小注；空文本且无工具的气泡（纯 thinking 占位）跳过。
    public static func loadCursor(dbPath: String, composerId: String, maxMessages: Int) -> Result {
        guard let db = try? SQLiteDB(path: dbPath, readOnly: true),
            let composer = cursorJSON(
                db: db, key: "composerData:\(composerId)")
        else { return Result(messages: [], truncated: false) }

        let bubbleIds = (composer["fullConversationHeadersOnly"] as? [[String: Any]] ?? [])
            .compactMap { $0["bubbleId"] as? String }
        var messages: [TranscriptMessage] = []
        var truncated = false

        for bubbleId in bubbleIds {
            guard messages.count < maxMessages else {
                truncated = true
                break
            }
            guard let bubble = cursorJSON(
                db: db, key: "bubbleId:\(composerId):\(bubbleId)") else { continue }
            let timestamp = (bubble["createdAt"] as? String).flatMap { iso8601.date(from: $0) }

            if let tool = bubble["toolFormerData"] as? [String: Any],
                let name = tool["name"] as? String, !name.isEmpty {
                messages.append(TranscriptMessage(
                    id: messages.count, role: .toolNote,
                    text: "🔧 \(CursorToolNames.displayName(name))", timestamp: timestamp))
                guard messages.count < maxMessages else {
                    truncated = true
                    break
                }
            }
            let text = (bubble["text"] as? String) ?? ""
            guard !text.isEmpty else { continue }
            let role: TranscriptMessage.Role =
                (bubble["type"] as? NSNumber)?.intValue == 1 ? .user : .assistant
            messages.append(TranscriptMessage(
                id: messages.count, role: role, text: text, timestamp: timestamp))
        }
        return Result(messages: messages, truncated: truncated)
    }

    private static func cursorJSON(db: SQLiteDB, key: String) -> [String: Any]? {
        let rows = (try? db.query(
            "SELECT value FROM cursorDiskKV WHERE key = ?", [.text(key)]) { $0.text(0) }) ?? []
        guard let text = rows.first.flatMap({ $0 }), let data = text.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - CodeBuddy（projects/<cwd-slug>/<sessionId>.jsonl；message/function_call 行）

    /// user input_text → 用户消息（skipRun 元行跳过）；assistant output_text → 助手消息；
    /// function_call → 🔧 工具小注，function_call_result 仅失败（status != completed）记错误注；
    /// reasoning / file-history-snapshot / ai-title / summary 跳过。
    public static func loadCodeBuddy(path: String, maxMessages: Int) -> Result {
        var messages: [TranscriptMessage] = []
        var truncated = false

        forEachJSONLine(path: path) { root in
            guard messages.count < maxMessages else {
                truncated = true
                return false
            }
            let timestamp = CodeBuddyTranscriptDecoder.timestamp(root)
            if let text = CodeBuddyTranscriptDecoder.userText(root) {
                messages.append(TranscriptMessage(
                    id: messages.count, role: .user, text: text, timestamp: timestamp))
            } else if let text = CodeBuddyTranscriptDecoder.assistantText(root) {
                messages.append(TranscriptMessage(
                    id: messages.count, role: .assistant, text: text, timestamp: timestamp))
            } else if let call = CodeBuddyTranscriptDecoder.toolCall(root) {
                messages.append(TranscriptMessage(
                    id: messages.count, role: .toolNote,
                    text: "🔧 \(call.name)", timestamp: timestamp))
            } else if root["type"] as? String == "function_call_result",
                      root["status"] as? String != "completed" {
                let name = root["name"] as? String ?? "工具"
                let status = root["status"] as? String ?? "失败"
                messages.append(TranscriptMessage(
                    id: messages.count, role: .error,
                    text: "🔧 \(name)：\(status)", timestamp: timestamp))
            }
            return true
        }
        return Result(messages: messages, truncated: truncated)
    }

    // MARK: - Qoder（projects/<slug>/<sessionId>.jsonl；Claude 式信封，规则同 loadClaude 裁剪）

    /// 与 loadClaude 同构：human 用户正文（origin.kind=="human"、非 isMeta）→ 用户消息；
    /// assistant text → 助手消息；tool_use 聚成轮轨迹（tool_result is_error 回填）；
    /// thinking / runtime-config / workspace-directories / last-prompt / 标题行等跳过。
    public static func loadQoder(path: String, maxMessages: Int) -> Result {
        var messages: [TranscriptMessage] = []
        var truncated = false
        var trailIndex: Int?
        var stepAt: [String: (msg: Int, step: Int)] = [:]
        var stepCount = 0
        var batch = 0
        func withinBudget() -> Bool { messages.count + stepCount < maxMessages }

        forEachJSONLine(path: path) { root in
            guard withinBudget() else {
                truncated = true
                return false
            }
            let timestamp = QoderTranscriptDecoder.timestamp(root)
            switch root["type"] as? String {
            case "user":
                if let text = QoderTranscriptDecoder.userPromptText(root) {
                    // 真实用户提问 = 新一轮
                    trailIndex = nil
                    batch = 0
                    messages.append(TranscriptMessage(
                        id: messages.count, role: .user, text: text, timestamp: timestamp))
                } else if let message = root["message"] as? [String: Any],
                          let blocks = message["content"] as? [[String: Any]] {
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
                guard let message = root["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]]
                else { return true }
                batch += 1
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
                            id: messages.count, role: .assistant,
                            text: text, timestamp: timestamp))
                    case "tool_use":
                        let name = block["name"] as? String ?? "工具"
                        var step = ToolStepExtractor.claude(
                            name: name, input: block["input"] as? [String: Any])
                        step.batch = batch
                        step.callId = block["id"] as? String
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
                    case "thinking":
                        appendThinkingIfPresent(block, timestamp: timestamp, into: &messages)
                    default:
                        break
                    }
                }
            default:
                break  // 标题行 / runtime-config / workspace-directories / system 等跳过
            }
            return true
        }
        backfillTrailText(&messages)
        return Result(messages: messages, truncated: truncated)
    }

    // MARK: - Hermes（~/.hermes/state.db 的 messages 表；role=tool 转工具注记）

    /// Hermes 把消息全部存在 state.db（无逐会话 JSONL）。timestamp 是 epoch **秒**（opencode 那张表是毫秒）。
    /// 只读打开：SQLITE_OPEN_READONLY + 普通路径 → WAL 可见（不能用 immutable=1，会读到旧数据）。
    public static func loadHermes(dbPath: String, sessionId: String, maxMessages: Int) -> Result {
        guard let db = try? SQLiteDB(path: dbPath, readOnly: true) else {
            return Result(messages: [], truncated: false)
        }
        var messages: [TranscriptMessage] = []
        var truncated = false
        let rows = (try? db.query("""
        SELECT role, content, tool_name, timestamp FROM messages
        WHERE session_id = ? ORDER BY timestamp, id
        """, [.text(sessionId)]) { row -> (String, String, String, Double) in
            (row.text(0) ?? "", row.text(1) ?? "", row.text(2) ?? "", row.real(3))
        }) ?? []

        for (role, content, toolName, epoch) in rows {
            guard messages.count < maxMessages else {
                truncated = true
                break
            }
            let timestamp = Date(timeIntervalSince1970: epoch)
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            switch role {
            case "user", "assistant":
                guard !text.isEmpty else { continue }
                messages.append(TranscriptMessage(
                    id: messages.count, role: role == "user" ? .user : .assistant,
                    text: text, timestamp: timestamp))
            case "tool":
                messages.append(TranscriptMessage(
                    id: messages.count, role: .toolNote,
                    text: "🔧 \(toolName.isEmpty ? "工具" : toolName)", timestamp: timestamp))
            default:
                break  // system / 其它角色不进正文
            }
        }
        return Result(messages: messages, truncated: truncated)
    }

    // MARK: - Qwen（projects/<encoded>/chats/<uuid>.jsonl）

    /// `{text, thought:true}` part 是**明文思考**（实勘单段 5000+ 字符）→ 出 `.thinking`；
    /// functionCall → 🔧 小注。

    public static func loadQwen(path: String, maxMessages: Int) -> Result {
        var messages: [TranscriptMessage] = []
        var truncated = false
        var seenIds = Set<String>()  // 防会话恢复整写文件产生的重复行

        forEachJSONLine(path: path) { root in
            guard messages.count < maxMessages else {
                truncated = true
                return false
            }
            guard let message = QwenChatDecoder.parseMessage(root) else { return true }
            if let id = message.uuid, !seenIds.insert(id).inserted { return true }
            switch message.type {
            case "user" where !message.text.isEmpty:
                messages.append(TranscriptMessage(
                    id: messages.count, role: .user, text: message.text,
                    timestamp: message.timestamp))
            case "assistant":
                // 思考在工具与回答之前：模型是先想再动手
                for thought in message.thoughts {
                    messages.append(TranscriptMessage(
                        id: messages.count, role: .thinking,
                        text: clipThinking(thought), timestamp: message.timestamp))
                }
                for tool in message.toolCalls {
                    messages.append(TranscriptMessage(
                        id: messages.count, role: .toolNote,
                        text: "🔧 \(tool)", timestamp: message.timestamp))
                }
                if !message.text.isEmpty {
                    messages.append(TranscriptMessage(
                        id: messages.count, role: .assistant, text: message.text,
                        timestamp: message.timestamp))
                }
            default:
                break  // system（注入/telemetry）不进对话流
            }
            return true
        }
        return Result(messages: messages, truncated: truncated)
    }

    // MARK: - Gemini（chats/session-*.jsonl；$set 补丁行与注入的 session_context 跳过）

    public static func loadGemini(path: String, maxMessages: Int) -> Result {
        var messages: [TranscriptMessage] = []
        var truncated = false
        // CLI 流式写入会把同一消息行重复写（真实观测）→ 按消息 id 去重
        var seenIds = Set<String>()

        forEachJSONLine(path: path) { root in
            guard messages.count < maxMessages else {
                truncated = true
                return false
            }
            guard let message = GeminiChatDecoder.parseMessage(root) else { return true }
            if let id = message.id, !seenIds.insert(id).inserted { return true }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return true }
            switch message.type {
            case "user" where !GeminiChatDecoder.isSessionContext(message.text):
                messages.append(TranscriptMessage(
                    id: messages.count, role: .user, text: text,
                    timestamp: message.timestamp))
            case "gemini":
                messages.append(TranscriptMessage(
                    id: messages.count, role: .assistant, text: text,
                    timestamp: message.timestamp))
            case "error":
                messages.append(TranscriptMessage(
                    id: messages.count, role: .error, text: text,
                    timestamp: message.timestamp))
            default:
                break  // info / session_context 注入不进对话流
            }
            return true
        }
        return Result(messages: messages, truncated: truncated)
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
        // 批次号：一条 assistant 消息的 content 数组里的 tool_use 是**同一次模型输出**，
        // 即真正的并行调用；跨消息就是串行。血缘图靠它区分分叉与链。
        var batch = 0
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
                    batch = 0
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
                batch += 1  // 每条 assistant 消息一批
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
                        var step = ToolStepExtractor.claude(
                            name: name, input: block["input"] as? [String: Any])
                        step.batch = batch
                        step.callId = block["id"] as? String
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
                    case "thinking":
                        // 实勘恒为空串（只剩加密 signature）→ 这里等于不触发；
                        // 写成条件是为了 Claude 哪天不再剥离就自动生效。
                        appendThinkingIfPresent(block, timestamp: timestamp, into: &messages)
                    default:
                        break
                    }
                }
            default:
                break  // ai-title / system / summary 等跳过
            }
            return true
        }
        attachSubagentTrails(&messages, mainTranscriptPath: path)
        backfillTrailText(&messages)
        return Result(messages: messages, truncated: truncated)
    }

    /// 把 `subagents/agent-*.jsonl` 的步骤挂到对应的 `.agent` 步上（按 `toolUseId` 精确配对）。
    /// 目录不存在（没派生过子代理）时是零成本 no-op。
    static func attachSubagentTrails(
        _ messages: inout [TranscriptMessage], mainTranscriptPath: String
    ) {
        let hasAgentStep = messages.contains { message in
            message.steps.contains { $0.kind == .agent && $0.callId != nil }
        }
        guard hasAgentStep else { return }
        let trails = SubagentTrailLoader.load(mainTranscriptPath: mainTranscriptPath)
        guard !trails.isEmpty else { return }
        for messageIndex in messages.indices {
            for stepIndex in messages[messageIndex].steps.indices {
                let step = messages[messageIndex].steps[stepIndex]
                guard step.kind == .agent, let callId = step.callId,
                    let subSteps = trails[callId]
                else { continue }
                messages[messageIndex].steps[stepIndex].subSteps = subSteps
            }
        }
    }

    // MARK: - Codex（~/.codex/sessions/.../rollout-*.jsonl）

    /// 正文用 event_msg（user_message / agent_message 纯字符串）；
    /// 工具轨迹用 response_item（**custom_tool_call** / function_call / web_search_call）
    /// + event_msg 的 mcp_tool_call_end。
    ///
    /// 两处与旧注释不同、都是实勘纠正的：
    ///  1. **`custom_tool_call` 才是当前 Codex 的命令/补丁主通道**（实勘 12 个最大 rollout：
    ///     `exec` 1334 + `apply_patch` 97）。以前完全没解析 → Codex 轨迹是残缺的。
    ///  2. **思考明文可得**：加密的是 `response_item/reasoning`（`encrypted_content`），
    ///     而 `event_msg/agent_reasoning.text` 是明文（实勘 265 条）。
    ///
    /// 轮边界优先用 rollout 自带的真 `turn_id`（覆盖 15 种行类型，实勘单文件 107 个 turn），
    /// 取不到才退回「用户消息 = 新一轮」。
    public static func loadCodex(path: String, maxMessages: Int) -> Result {
        var messages: [TranscriptMessage] = []
        var truncated = false
        var trailIndex: Int?
        // call_id → 步骤位置（工具结果行回填失败标记用）
        var stepAt: [String: (msg: Int, step: Int)] = [:]
        var stepCount = 0
        // 当前 turn_id 与批次号：同一 turn 内的相邻工具调用算同批（并行分叉判据）
        var currentTurnId: String?
        var batch = 0
        func withinBudget() -> Bool { messages.count + stepCount < maxMessages }
        func appendStep(_ step: ToolStep, callId: String?, timestamp: Date?) {
            var step = step
            step.batch = batch
            step.callId = callId
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
        /// 结果行回填：失败标记打到对应步骤上（判不出成败就不动）
        func markOutcome(callId: String?, output: Any?) {
            guard let callId, let pos = stepAt[callId],
                AuditExtractor.codexOutcome(output)?.isError == true
            else { return }
            messages[pos.msg].steps[pos.step].isError = true
        }

        forEachJSONLine(path: path) { root in
            guard withinBudget() else {
                truncated = true
                return false
            }
            guard let payload = root["payload"] as? [String: Any] else { return true }
            let timestamp = (root["timestamp"] as? String).flatMap(parseTimestamp)
            // 真 turn_id 换了就是新一轮（比「用户消息」更准：工具续跑不会误判）
            if let turnId = codexTurnId(payload), turnId != currentTurnId {
                currentTurnId = turnId
                trailIndex = nil
                batch = 0
            }
            switch root["type"] as? String {
            case "event_msg":
                switch payload["type"] as? String {
                case "user_message":
                    if let text = payload["message"] as? String, !text.isEmpty {
                        trailIndex = nil  // 用户消息 = 新一轮（turn_id 缺失时的兜底）
                        batch = 0
                        messages.append(TranscriptMessage(
                            id: messages.count, role: .user, text: text, timestamp: timestamp))
                    }
                case "agent_reasoning":
                    // 明文思考（加密的是 response_item/reasoning，不是这条）
                    if let text = payload["text"] as? String,
                        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        messages.append(TranscriptMessage(
                            id: messages.count, role: .thinking,
                            text: clipThinking(text), timestamp: timestamp))
                        batch += 1  // 思考之后是新一批工具调用
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
                case "custom_tool_call":
                    // 当前 Codex 的命令/补丁主通道；input 不是 JSON（JS 源码或补丁正文）
                    guard let name = payload["name"] as? String, !name.isEmpty
                    else { return true }
                    appendStep(
                        ToolStepExtractor.codexCustomTool(
                            name: name, input: payload["input"] as? String),
                        callId: payload["call_id"] as? String, timestamp: timestamp)
                case "custom_tool_call_output":
                    markOutcome(
                        callId: payload["call_id"] as? String, output: payload["output"])
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
                    // 从输出文本判失败。旧版读 `metadata.exit_code`，但**当前 Codex 已无该字段**
                    // （实勘 2624 条 function_call_output 中 metadata 出现 0 次）→ 那是死代码。
                    markOutcome(
                        callId: payload["call_id"] as? String, output: payload["output"])
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

    /// rollout 行里的真 `turn_id`。实勘落在 `internal_chat_message_metadata_passthrough.turn_id`
    /// 或 payload 顶层（`task_started` / `task_complete` / `turn_aborted`）。
    static func codexTurnId(_ payload: [String: Any]) -> String? {
        if let passthrough = payload["internal_chat_message_metadata_passthrough"]
            as? [String: Any], let id = passthrough["turn_id"] as? String, !id.isEmpty {
            return id
        }
        if let id = payload["turn_id"] as? String, !id.isEmpty { return id }
        return nil
    }

    /// 思考正文上限：Kimi 单段实测可达 19.5k 字符，整段驻留内存不值当。
    /// 比工具参数（160）宽松得多——思考的价值就在于能读，但也必须有上界。
    static let thinkingLimit = 1200

    static func clipThinking(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count <= thinkingLimit
            ? text : String(text.prefix(thinkingLimit)) + "…"
    }

    /// Claude 式 `thinking` 块 → 思考消息，**正文为空就什么都不做**。
    ///
    /// 对 Claude 这是个恒不触发的分支（实勘 377 个 `thinking` 块的 `thinking` 字段全是空串，
    /// 只剩 9848 字符的加密 `signature`）；写成条件而不是写死「Claude 没有」，
    /// 是为了它哪天不再剥离就自动生效，也让同构的 Qoder 直接受益。
    static func appendThinkingIfPresent(
        _ block: [String: Any], timestamp: Date?, into messages: inout [TranscriptMessage]
    ) {
        guard let raw = block["thinking"] as? String,
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        messages.append(TranscriptMessage(
            id: messages.count, role: .thinking,
            text: clipThinking(raw), timestamp: timestamp))
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
    /// assistant 正文 = loop 事件 content.part(part.type=text) 整段；
    /// **think 段是明文思考**（实勘 235 段，最长 19.5k）→ 单独出 `.thinking` 消息；
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
            } else if let think = KimiWireDecoder.thinkText(root) {
                messages.append(TranscriptMessage(
                    id: messages.count, role: .thinking,
                    text: clipThinking(think), timestamp: timestamp))
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
            case .thinking:
                // 引用块：思考不是回答，导出时要与正文区分开
                lines.append("> 💭 思考\(time)")
                lines.append(">")
                for line in message.text.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("> \(line)")
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
