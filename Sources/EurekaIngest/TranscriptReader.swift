import EurekaKit
import EurekaStore
import Foundation

/// One conversation message (unified model across the Claude / Codex / opencode sources, for the
/// session viewer)
public struct TranscriptMessage: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case user
        case assistant
        case toolNote   // tool call note (🔧 <name>, used by opencode/grok/antigravity)
        case error      // API errors etc.
        case turnTrail  // per-turn tool/retrieval trail aggregate (from Claude/Codex; steps hold the details)
        /// Model thinking text. **Only some sources have it** (Codex `agent_reasoning` / Kimi
        /// `think` / Qwen `thought`); Claude's `thinking` blocks have their text stripped when
        /// written to disk, leaving only the encrypted signature, so Claude never produces this
        /// role.
        case thinking
    }

    /// Index within the file (jump anchor for the conversation outline)
    public let id: Int
    public var role: Role
    /// For turnTrail, text is the plain-text rendering of the trail (so in-session search and the
    /// export fallback can match it)
    public var text: String
    public var timestamp: Date?
    /// Tool trail details (non-empty only when role == .turnTrail)
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

/// Session transcript reader: parses the whole file (tolerantly skipping bad lines) and truncates
/// past the limit.
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

    /// Default load budget. Claude's budget counts both messages and tool steps (a real 13k-line
    /// session at 2000 rendered only 1241 messages before truncating); LazyVStack builds rows
    /// lazily, so the limit only guards against pathologically huge files, not rendering cost.
    public static let defaultMaxMessages = 20_000

    /// Single entry point: dispatches by source
    public static func load(
        session: AgentSessionInfo, maxMessages: Int = defaultMaxMessages
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
        case .trae:
            return loadTrae()
        case .zcode:
            // zcode's message/part tables mirror opencode's (a sqlite database with the same
            // schema); transcriptPath carries the db path
            return loadOpencode(
                dbPath: session.transcriptPath, sessionId: session.id,
                maxMessages: maxMessages)
        }
    }

    // MARK: - Trae (session database is encrypted; only a one-line note is possible)

    /// Trae's session content lives in `ModularData/ai-agent/database.db`, which is **SQLCipher
    /// encrypted** (the first 16 bytes are a random salt; `sqlite3` reports "file is not a
    /// database"), and there is no plaintext transcript anywhere on the machine. So the content is
    /// never available; as with Antigravity, show a one-line note instead of a blank page. The
    /// session itself stays visible (title/time come from the plaintext memory library; see
    /// `TraeSessionIndexer`).
    public static func loadTrae() -> Result {
        Result(
            messages: [TranscriptMessage(
                id: 0, role: .toolNote,
                text: L10n.text("🔒 Trae's session database is encrypted with SQLCipher, so its content cannot be read; this page uses Trae's plaintext memory library", zhHans: "🔒 Trae 的会话库经 SQLCipher 加密，正文无法读取；本页信息来自 Trae 的明文记忆库"))],
            truncated: false)
    }

    // MARK: - Cursor (state.vscdb read-only: composerData gives bubble order, bubbleId rows give text)

    /// Message order comes from `composerData.fullConversationHeadersOnly` (bubbles are scattered
    /// in the KV store with keys sorted by uuid; only this table knows the order). `type`
    /// 1=user / 2=assistant; `toolFormerData` becomes a 🔧 note; bubbles with empty text and no
    /// tool (pure thinking placeholders) are skipped.
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

    // MARK: - CodeBuddy (projects/<cwd-slug>/<sessionId>.jsonl; message/function_call lines)

    /// user input_text → user message (skipRun meta lines skipped); assistant output_text →
    /// assistant message; function_call → 🔧 tool note; function_call_result becomes an error
    /// note only on failure (status != completed); reasoning / file-history-snapshot / ai-title /
    /// summary are skipped.
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
                let name = root["name"] as? String ?? L10n.text("Tool", zhHans: "工具")
                let status = root["status"] as? String ?? L10n.text("Failed", zhHans: "失败")
                messages.append(TranscriptMessage(
                    id: messages.count, role: .error,
                    text: L10n.format("🔧 %@: %@", zhHans: "🔧 %@：%@", String(name), String(status)), timestamp: timestamp))
            }
            return true
        }
        return Result(messages: messages, truncated: truncated)
    }

    // MARK: - Qoder (projects/<slug>/<sessionId>.jsonl; Claude-style envelope, a trimmed loadClaude)

    /// Mirrors loadClaude: human user text (origin.kind=="human", not isMeta) → user message;
    /// assistant text → assistant message; tool_use aggregated into the turn trail (tool_result
    /// is_error back-filled); thinking / runtime-config / workspace-directories / last-prompt /
    /// title lines etc. are skipped.
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
                    // A real user prompt = a new turn
                    trailIndex = nil
                    batch = 0
                    messages.append(TranscriptMessage(
                        id: messages.count, role: .user, text: text, timestamp: timestamp))
                } else if let message = root["message"] as? [String: Any],
                          let blocks = message["content"] as? [[String: Any]] {
                    // Array = tool_result: not part of the text; only back-fills failure flags
                    // by tool_use_id
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
                        let name = block["name"] as? String ?? L10n.text("Tool", zhHans: "工具")
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
                break  // title lines / runtime-config / workspace-directories / system etc. skipped
            }
            return true
        }
        backfillTrailText(&messages)
        return Result(messages: messages, truncated: truncated)
    }

    // MARK: - Hermes (messages table in ~/.hermes/state.db; role=tool becomes a tool note)

    /// Hermes stores every message in state.db (no per-session JSONL). timestamp is epoch
    /// **seconds** (opencode's table uses milliseconds).
    /// Opened read-only: SQLITE_OPEN_READONLY + a plain path → WAL is visible (immutable=1 must not
    /// be used; it would read stale data).
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
                    text: "🔧 \(toolName.isEmpty ? L10n.text("Tool", zhHans: "工具") : toolName)", timestamp: timestamp))
            default:
                break  // system / other roles stay out of the text
            }
        }
        return Result(messages: messages, truncated: truncated)
    }

    // MARK: - Qwen (projects/<encoded>/chats/<uuid>.jsonl)

    /// A `{text, thought:true}` part is **plaintext thinking** (a single part measured 5000+
    /// characters locally) → emits `.thinking`; functionCall → 🔧 note.

    public static func loadQwen(path: String, maxMessages: Int) -> Result {
        var messages: [TranscriptMessage] = []
        var truncated = false
        var seenIds = Set<String>()  // guards against duplicate lines from session resume rewriting the file

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
                // Thinking comes before tools and the answer: the model thinks, then acts
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
                break  // system (injection/telemetry) stays out of the conversation stream
            }
            return true
        }
        return Result(messages: messages, truncated: truncated)
    }

    // MARK: - Gemini (chats/session-*.jsonl; $set patch lines and injected session_context skipped)

    public static func loadGemini(path: String, maxMessages: Int) -> Result {
        var messages: [TranscriptMessage] = []
        var truncated = false
        // CLI streaming writes the same message line repeatedly (observed in practice) → dedup by
        // message id
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
                break  // info / injected session_context stays out of the conversation stream
            }
            return true
        }
        return Result(messages: messages, truncated: truncated)
    }

    // MARK: - Antigravity (conversations/<uuid>.db; content is proprietary binary protobuf)

    /// Antigravity session content lives entirely in protobuf blobs (Google hasn't published the
    /// schema), which this dependency-free project can't decode. Returns one explanatory note so a
    /// blank detail page doesn't mislead.
    public static func loadAntigravity() -> Result {
        Result(
            messages: [TranscriptMessage(
                id: 0, role: .toolNote,
                text: L10n.text("🔒 Antigravity conversations use a proprietary binary (protobuf) format; content previews are not supported yet", zhHans: "🔒 Antigravity 对话为私有二进制（protobuf）格式，暂不支持正文预览"))],
            truncated: false)
    }

    // MARK: - Claude (~/.claude/projects/<encoded>/<session>.jsonl)

    public static func loadClaude(path: String, maxMessages: Int) -> Result {
        var messages: [TranscriptMessage] = []
        var truncated = false
        // Per-turn tool trail: created lazily where the turn's first tool_use appears; later steps
        // are appended in place
        var trailIndex: Int?
        // tool_use_id → step position (for back-filling tool_result is_error)
        var stepAt: [String: (msg: Int, step: Int)] = [:]
        // Steps count toward the truncation budget (approximates the old accounting: each tool_use
        // used to take one toolNote; now each turn counts 1 extra for the trail container)
        var stepCount = 0
        // Batch number: tool_uses in one assistant message's content array are **one model
        // output**, i.e. truly parallel calls; across messages they are serial. The lineage graph
        // uses it to tell forks from chains.
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
                    // A real user prompt = a new turn
                    trailIndex = nil
                    batch = 0
                    messages.append(TranscriptMessage(
                        id: messages.count, role: .user, text: content, timestamp: timestamp))
                } else if let blocks = message["content"] as? [[String: Any]] {
                    // Array = tool_result: not part of the text; only back-fills failure flags
                    // by tool_use_id
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
                batch += 1  // one batch per assistant message
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
                        let name = block["name"] as? String ?? L10n.text("Tool", zhHans: "工具")
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
                        // Always an empty string in practice (only the encrypted signature
                        // remains) → effectively never fires; it's conditional so it takes
                        // effect automatically if Claude ever stops stripping it.
                        appendThinkingIfPresent(block, timestamp: timestamp, into: &messages)
                    default:
                        break
                    }
                }
            default:
                break  // ai-title / system / summary etc. skipped
            }
            return true
        }
        attachSubagentTrails(&messages, mainTranscriptPath: path)
        backfillTrailText(&messages)
        return Result(messages: messages, truncated: truncated)
    }

    /// Attaches the steps from `subagents/agent-*.jsonl` to the matching `.agent` step (paired
    /// exactly by `toolUseId`). A zero-cost no-op when the directory doesn't exist (no subagent
    /// was spawned).
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

    // MARK: - Codex (~/.codex/sessions/.../rollout-*.jsonl)

    /// Message text comes in two format generations, and both must be recognized:
    /// - **Current** (Desktop / TUI / Chrome extension; every local 2026 rollout has switched):
    ///   `event_msg/item_completed` with `item.type` `UserMessage` / `AgentMessage`, text in
    ///   `content[]` (user `type:text`, assistant `type:Text`).
    ///   The old plain-string `user_message` / `agent_message` appear 0 times in these files;
    ///   parsing only the old fields leaves the session detail with just the tool trail, and
    ///   filtering to "User" or "Assistant" shows nothing.
    /// - **Legacy**: plain-string `user_message` / `agent_message` in `event_msg`. Test fixtures
    ///   and older rollouts still go this way, so it can't be removed.
    ///
    /// `response_item/message` duplicates the two above (plus developer instructions and
    /// environment_context) and stays skipped. Imported external sessions stuff tool calls into
    /// an `AgentMessage` with no `phase` (`[external_agent_tool_call:…]` /
    /// `[external_agent_tool_result]`); those aren't replies and are dropped.
    ///
    /// The tool trail uses response_item (**custom_tool_call** / function_call / web_search_call)
    /// + event_msg mcp_tool_call_end.
    ///
    /// Two points differ from the old comment, both corrected by local inspection:
    ///  1. **`custom_tool_call` is current Codex's main command/patch channel** (the 12 largest
    ///     local rollouts: `exec` 1334 + `apply_patch` 97). It used to be ignored entirely → the
    ///     Codex trail was incomplete.
    ///  2. **Plaintext thinking is available**: the encrypted one is `response_item/reasoning`
    ///     (`encrypted_content`), while `event_msg/agent_reasoning.text` is plaintext (265 lines
    ///     locally). The new format's `item_completed/Reasoning` has an empty `summary_text` in
    ///     every local sample, so it doesn't get its own message.
    ///
    /// Turn boundaries prefer the rollout's own real `turn_id` (present on 15 line types; 107
    /// turns in a single local file), falling back to "user message = new turn" only when it's
    /// missing.
    public static func loadCodex(path: String, maxMessages: Int) -> Result {
        var messages: [TranscriptMessage] = []
        var truncated = false
        var trailIndex: Int?
        // call_id → step position (for back-filling failure flags from tool result lines)
        var stepAt: [String: (msg: Int, step: Int)] = [:]
        var stepCount = 0
        // Current turn_id and batch number: adjacent tool calls within one turn count as one
        // batch (the parallel-fork criterion)
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
        /// Result-line back-fill: marks failure on the matching step (left alone when the outcome
        /// can't be determined)
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
            // A changed real turn_id means a new turn (more accurate than "user message": tool
            // continuations aren't misjudged)
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
                        trailIndex = nil  // user message = new turn (fallback when turn_id is missing)
                        batch = 0
                        messages.append(TranscriptMessage(
                            id: messages.count, role: .user, text: text, timestamp: timestamp))
                    }
                case "agent_reasoning":
                    // Plaintext thinking (the encrypted one is response_item/reasoning, not this)
                    if let text = payload["text"] as? String,
                        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        messages.append(TranscriptMessage(
                            id: messages.count, role: .thinking,
                            text: clipThinking(text), timestamp: timestamp))
                        batch += 1  // a new batch of tool calls follows thinking
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
                    // The clean MCP name lives here (function_call holds "_"-prefixed
                    // duplicates); result.Err marks an error
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
                case "item_completed":
                    guard let item = payload["item"] as? [String: Any] else { break }
                    switch item["type"] as? String {
                    case "UserMessage":
                        if let text = codexItemVisibleText(item, userFacing: true) {
                            trailIndex = nil  // user message = new turn (fallback when turn_id is missing)
                            batch = 0
                            messages.append(TranscriptMessage(
                                id: messages.count, role: .user, text: text, timestamp: timestamp))
                        }
                    case "AgentMessage":
                        if let text = codexItemVisibleText(item, userFacing: false) {
                            messages.append(TranscriptMessage(
                                id: messages.count, role: .assistant, text: text,
                                timestamp: timestamp))
                        }
                    default:
                        break  // CommandExecution / Reasoning etc.: the trail already comes from response_item
                    }
                default:
                    break
                }
            case "response_item":
                switch payload["type"] as? String {
                case "custom_tool_call":
                    // Current Codex's main command/patch channel; input isn't JSON (JS source or
                    // a patch body)
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
                    // "_" prefix = MCP duplicate, skipped (same rule as CodexUsageScanner)
                    guard let name = payload["name"] as? String, !name.isEmpty,
                          !name.hasPrefix("_")
                    else { return true }
                    appendStep(
                        ToolStepExtractor.codex(
                            name: name, argumentsJSON: payload["arguments"] as? String),
                        callId: payload["call_id"] as? String, timestamp: timestamp)
                case "function_call_output":
                    // Failure is judged from the output text. The old version read
                    // `metadata.exit_code`, but **current Codex no longer has that field**
                    // (metadata appeared 0 times in 2624 local function_call_output lines) → that
                    // was dead code.
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
                    break  // reasoning (encrypted) / message (duplicates event_msg) etc. skipped
                }
            default:
                break  // session_meta / turn_context etc. skipped
            }
            return true
        }
        backfillTrailText(&messages)
        return Result(messages: messages, truncated: truncated)
    }

    /// Visible text of an `item_completed`.
    ///
    /// On the user side, the Chrome extension wraps the real input in tab descriptions and
    /// "## My request:", repeated every turn; the session page keeps only the request itself.
    /// Attached images have no image view, so their file names are recorded.
    /// On the assistant side, tool protocol lines from imported sessions are dropped; historical
    /// replies without a `phase` must still be kept (`commentary` / `final_answer` were added
    /// later).
    static func codexItemVisibleText(_ item: [String: Any], userFacing: Bool) -> String? {
        let parts: [Any]
        if let content = item["content"] as? [Any] {
            parts = content
        } else if let text = item["content"] as? String {
            parts = [["type": "text", "text": text] as [String: Any]] as [Any]
        } else {
            return nil
        }
        var texts: [String] = []
        var images: [String] = []
        for case let part as [String: Any] in parts {
            let type = (part["type"] as? String)?.lowercased() ?? ""
            if type == "text" || type == "output_text" || type == "input_text" {
                if let text = part["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { texts.append(trimmed) }
                }
            } else if type == "local_image" {
                let name = (part["path"] as? String).map {
                    URL(fileURLWithPath: $0).lastPathComponent
                } ?? ""
                images.append(name.isEmpty ? L10n.text("(Attached image)", zhHans: "（附图）") : L10n.format("(Attached image: %@)", zhHans: "（附图：%@）", String(name)))
            }
        }
        var body = texts.joined(separator: "\n\n")
        if userFacing {
            body = unwrapCodexUserEnvelope(body)
        } else if codexAgentTextIsProtocolNoise(body) {
            return nil
        }
        var lines: [String] = []
        if !body.isEmpty { lines.append(body) }
        lines.append(contentsOf: images)
        let joined = lines.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    /// The Chrome extension / pasted attachments wrap model instructions around the user input.
    /// Only these two known prefixes are recognized, so ordinary messages that happen to contain
    /// "My request" aren't mangled.
    static func unwrapCodexUserEnvelope(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let enveloped = trimmed.hasPrefix("# Chrome tabs:")
            || trimmed.hasPrefix("# Files mentioned by the user:")
        guard enveloped, let range = trimmed.range(of: "## My request:") else { return trimmed }
        let body = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? trimmed : body
    }

    /// Imported external agents record tool calls as AgentMessage. These lines aren't replies
    /// meant for the user.
    static func codexAgentTextIsProtocolNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[external_agent_tool_call:") { return true }
        if trimmed.hasPrefix("[external_agent_tool_result]") { return true }
        if trimmed.hasPrefix("<EXTERNAL SESSION IMPORTED>") { return true }
        return false
    }

    /// The real `turn_id` in a rollout line. Locally it sits in
    /// `internal_chat_message_metadata_passthrough.turn_id` or at the payload top level
    /// (`task_started` / `task_complete` / `turn_aborted` / `item_completed`).
    static func codexTurnId(_ payload: [String: Any]) -> String? {
        if let passthrough = payload["internal_chat_message_metadata_passthrough"]
            as? [String: Any], let id = passthrough["turn_id"] as? String, !id.isEmpty {
            return id
        }
        if let id = payload["turn_id"] as? String, !id.isEmpty { return id }
        return nil
    }

    /// Thinking text limit: a single Kimi segment measured up to 19.5k characters, not worth
    /// keeping whole in memory. Far looser than tool arguments (160): thinking is only valuable
    /// if readable, but it still needs an upper bound.
    static let thinkingLimit = 1200

    static func clipThinking(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count <= thinkingLimit
            ? text : String(text.prefix(thinkingLimit)) + "…"
    }

    /// Claude-style `thinking` block → thinking message; **does nothing when the text is empty**.
    ///
    /// For Claude this branch never fires (all 377 local `thinking` blocks had an empty
    /// `thinking` field, leaving only a 9848-character encrypted `signature`). It's written as a
    /// condition rather than hardcoding "Claude has none" so it takes effect automatically if
    /// Claude ever stops stripping, and so the same-shaped Qoder benefits directly.
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

    /// Final pass: back-fills the plain-text rendering into turnTrail messages (search/export
    /// fallback)
    private static func backfillTrailText(_ messages: inout [TranscriptMessage]) {
        for index in messages.indices where messages[index].role == .turnTrail {
            messages[index].text = ToolStepExtractor.plainText(messages[index].steps)
        }
    }

    // MARK: - opencode (opencode.db read-only: role from the message table + text from the part table)

    public static func loadOpencode(dbPath: String, sessionId: String, maxMessages: Int) -> Result {
        guard let db = try? SQLiteDB(path: dbPath, readOnly: true) else {
            return Result(messages: [], truncated: false)
        }
        var messages: [TranscriptMessage] = []
        var truncated = false
        // Messages ordered by creation time; role lives in the message.data JSON
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

            // Text = all of the message's text parts concatenated; tool parts become notes
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
                    toolNames.append(part["tool"] as? String ?? L10n.text("Tool", zhHans: "工具"))
                default:
                    break  // reasoning / step-start etc. skipped
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

    // MARK: - grok (~/.grok/sessions/<enc>/<uuid>/chat_history.jsonl)

    /// user content is a [{type:text,text}] array; assistant content is a plain string.
    /// reasoning (encrypted) / tool_result (verbose) / backend_tool_call / system are all skipped.
    /// chat_history.jsonl has no per-message timestamps → fill them per turn from the turn_started
    /// times in the sibling events.jsonl: each real user prompt advances one turn, and every
    /// message in that turn shares the turn's start time (turn-level granularity).
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
                // A real prompt (no synthetic_reason; synthetic means a tool continuation)
                // advances the turn time
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

    // MARK: - kimi (~/.kimi-code/sessions/<ws>/<session>/agents/main/wire.jsonl)

    /// wire.jsonl is an event-sourced log (epoch-ms `time`; schema verified against real sessions):
    /// user text = the input text blocks of turn.prompt(origin=user);
    /// assistant text = the whole content.part(part.type=text) of loop events;
    /// **think segments are plaintext thinking** (235 segments locally, longest 19.5k) → emitted
    /// as separate `.thinking` messages;
    /// tool.call becomes a 🔧 note; metadata/config/usage etc. are skipped.
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

    /// turn_started times, in order, from the sibling events.jsonl (used to fill grok message
    /// times per turn)
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

    // MARK: - Helpers

    /// Parses jsonl line by line (bad/partial lines tolerantly skipped); body returning false
    /// stops early.
    ///
    /// One autoreleasepool per line: the bridged objects JSONSerialization produces
    /// (NSDictionary/NSString trees) are autoreleased, and without draining they aren't freed
    /// until the whole queue block ends. A full rescan (fingerprints cleared after a migration)
    /// parsing hundreds of transcripts back to back in one block was measured pushing app memory
    /// to 5.5GB. Strings kept in messages are already retained by the array and unaffected by
    /// draining.
    private static func forEachJSONLine(
        path: String, _ body: ([String: Any]) -> Bool
    ) {
        guard let data = FileManager.default.contents(atPath: path) else { return }
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let lineData = data[start..<end]
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
            guard !lineData.isEmpty else { continue }
            let proceed = autoreleasepool { () -> Bool in
                guard let root = (try? JSONSerialization.jsonObject(
                    with: Data(lineData))) as? [String: Any]
                else { return true }
                return body(root)
            }
            if !proceed { return }
        }
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        iso8601.date(from: raw) ?? ClaudeSessionFirstTimestamp.parse(raw)
    }
}

/// Renders a transcript as Markdown (for session export/copy). Pure function, unit-testable.
public enum TranscriptMarkdown {
    public static func render(session: AgentSessionInfo, messages: [TranscriptMessage]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines: [String] = ["# \(session.name ?? L10n.format("Session %@", zhHans: "会话 %@", String(session.id)))", ""]
        lines.append(L10n.format("- Source: %@", zhHans: "- 来源：%@", String(session.source.displayName)))
        if let cwd = session.cwd { lines.append(L10n.format("- Project: %@", zhHans: "- 项目：%@", String(cwd))) }
        lines.append(L10n.format("- Session ID: %@", zhHans: "- 会话 ID：%@", String(session.id)))
        lines.append("")
        for message in messages {
            let time = message.timestamp.map { " (\(formatter.string(from: $0)))" } ?? ""
            switch message.role {
            case .user:
                lines.append(L10n.format("## User%@", zhHans: "## 用户%@", String(time))); lines.append(""); lines.append(message.text)
            case .assistant:
                lines.append(L10n.format("## Assistant%@", zhHans: "## 助手%@", String(time))); lines.append(""); lines.append(message.text)
            case .error:
                lines.append(L10n.format("## Error%@", zhHans: "## 错误%@", String(time))); lines.append(""); lines.append(message.text)
            case .toolNote:
                lines.append("- \(message.text)")
            case .turnTrail:
                lines.append(L10n.format("- 🛠 Turn activity (%@ steps)", zhHans: "- 🛠 本轮轨迹（%@ 步）", String(message.steps.count)))
                for step in message.steps {
                    let flag = step.isError ? L10n.text(" (failed)", zhHans: "（失败）") : ""
                    let detail = step.detail.isEmpty ? "" : L10n.format(": %@", zhHans: "：%@", String(step.detail))
                    lines.append("  - [\(step.kind.label)] \(step.name)\(flag)\(detail)")
                }
            case .thinking:
                // Blockquote: thinking isn't the answer and must stay distinct from it in exports
                lines.append(L10n.format("> 💭 Thinking%@", zhHans: "> 💭 思考%@", String(time)))
                lines.append(">")
                for line in message.text.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("> \(line)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Makes a file name safe (strips path separators etc.)
    public static func safeFileName(_ name: String) -> String {
        String(name.map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 }).prefix(80).description
    }
}
