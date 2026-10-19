import EurekaKit
import Foundation

/// Normalized executor events (adapter-independent)
public enum SummaryExecutorEvent: Equatable {
    /// The CLI started a turn (`sessionId` is the executor's own id, never persisted as ours)
    case started(sessionId: String?, model: String?)
    /// Incremental text (only executors that stream deltas)
    case delta(String)
    /// A complete assistant message; replaces whatever was streamed for it
    case message(String)
}

/// What a parser learned from the whole stream
public final class SummaryParseState {
    public var finalText = ""
    public var model: String?
    public var executorSessionId: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// The adapter's terminal success event was seen (Claude `result` without error, Codex
    /// `turn.completed`, OpenCode final `step_finish`)
    public var succeeded = false
    public var errorMessage: String?
    public var jsonLines = 0
    public var nonJSONLines = 0

    public init() {}
}

public protocol SummaryOutputParser: AnyObject {
    var state: SummaryParseState { get }
    func consume(_ object: [String: Any]) -> [SummaryExecutorEvent]
}

/// One headless CLI contract, verified on real runs (docs/research/2026-10-19-session-summary-executors.md)
public protocol SummaryExecutorAdapter {
    var kind: SummaryExecutorKind { get }
    /// Whether the CLI streams incremental text
    var streams: Bool { get }
    /// Arguments that print the help text the availability probe inspects
    var helpArguments: [String] { get }
    /// Flags the adapter depends on; all must appear in the help text
    var requiredFlags: [String] { get }
    func arguments(workingDirectory: String, model: String?) -> [String]
    /// Extra environment on top of the login environment
    var extraEnvironment: [String: String] { get }
    func makeParser() -> SummaryOutputParser
}

func intValue(_ any: Any?) -> Int? {
    (any as? NSNumber)?.intValue
}

// MARK: - Claude Code

public struct ClaudeSummaryAdapter: SummaryExecutorAdapter {
    public init() {}

    public var kind: SummaryExecutorKind { .claude }
    public var streams: Bool { true }
    public var helpArguments: [String] { ["--help"] }
    public var requiredFlags: [String] {
        ["--output-format", "--include-partial-messages", "--no-session-persistence",
         "--tools", "--strict-mcp-config", "--settings"]
    }

    public func arguments(workingDirectory: String, model: String?) -> [String] {
        var args = [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            // Nothing written under ~/.claude/projects: no transcript to ingest or double count
            "--no-session-persistence",
            // No tools and no MCP servers: the snapshot on stdin is the only input
            "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
            // The user's hooks (Eureka's relay among them) must not see internal runs
            "--settings", #"{"disableAllHooks":true}"#,
        ]
        if let model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    /// Without it an empty auto-memory directory appears under ~/.claude/projects
    public var extraEnvironment: [String: String] { ["CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"] }

    public func makeParser() -> SummaryOutputParser { ClaudeStreamParser() }
}

final class ClaudeStreamParser: SummaryOutputParser {
    let state = SummaryParseState()

    func consume(_ object: [String: Any]) -> [SummaryExecutorEvent] {
        switch object["type"] as? String {
        case "system" where object["subtype"] as? String == "init":
            state.executorSessionId = object["session_id"] as? String
            state.model = object["model"] as? String ?? state.model
            return [.started(sessionId: state.executorSessionId, model: state.model)]
        case "stream_event":
            guard let event = object["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty
            else { return [] }
            return [.delta(text)]
        case "assistant":
            guard let message = object["message"] as? [String: Any] else { return [] }
            let text = (message["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            if let model = message["model"] as? String, model != "<synthetic>" {
                state.model = model
            }
            return text.isEmpty ? [] : [.message(text)]
        case "result":
            let text = object["result"] as? String ?? ""
            let isError = object["is_error"] as? Bool ?? true
            if !isError && object["subtype"] as? String == "success" {
                state.succeeded = true
                state.finalText = text
            } else {
                state.errorMessage = text.isEmpty
                    ? (object["subtype"] as? String ?? "error") : text
            }
            if let usage = object["usage"] as? [String: Any] {
                state.inputTokens = (intValue(usage["input_tokens"]) ?? 0)
                    + (intValue(usage["cache_creation_input_tokens"]) ?? 0)
                    + (intValue(usage["cache_read_input_tokens"]) ?? 0)
                state.outputTokens = intValue(usage["output_tokens"])
            }
            if state.model == nil, let models = object["modelUsage"] as? [String: Any] {
                state.model = models.keys.sorted().first
            }
            return []
        default:
            return []
        }
    }
}

// MARK: - Codex

public struct CodexSummaryAdapter: SummaryExecutorAdapter {
    /// Configured MCP server names (from `MCPConfigIndexer`): each is disabled by name, because
    /// `-c mcp_servers={}` merges instead of clearing
    public var mcpServerNames: [String]

    public init(mcpServerNames: [String] = []) {
        self.mcpServerNames = mcpServerNames
    }

    public var kind: SummaryExecutorKind { .codex }
    public var streams: Bool { false }
    public var helpArguments: [String] { ["exec", "--help"] }
    public var requiredFlags: [String] {
        ["--json", "--ephemeral", "--skip-git-repo-check", "--sandbox", "--disable", "--cd"]
    }

    public func arguments(workingDirectory: String, model: String?) -> [String] {
        var args = [
            "exec", "--json",
            // No rollout under ~/.codex/sessions: nothing to ingest or double count
            "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
            "--cd", workingDirectory,
            // Eureka's relay lives in ~/.codex/hooks.json; internal runs must not reach it
            "--disable", "hooks", "--disable", "plugins", "--disable", "memories",
            "--disable", "apps", "--disable", "multi_agent", "--disable", "shell_tool",
            "--disable", "image_generation",
            "-c", "notify=[]",
        ]
        for name in mcpServerNames where Self.isSafeKey(name) {
            args += ["-c", "mcp_servers.\(name).enabled=false"]
        }
        if let model, !model.isEmpty { args += ["--model", model] }
        args.append("-")  // read the prompt from stdin
        return args
    }

    /// Only bare TOML keys are passed through `-c` (no quoting games with arbitrary names)
    static func isSafeKey(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public var extraEnvironment: [String: String] { [:] }

    public func makeParser() -> SummaryOutputParser { CodexJSONParser() }
}

final class CodexJSONParser: SummaryOutputParser {
    let state = SummaryParseState()

    func consume(_ object: [String: Any]) -> [SummaryExecutorEvent] {
        switch object["type"] as? String {
        case "thread.started":
            state.executorSessionId = object["thread_id"] as? String
            return [.started(sessionId: state.executorSessionId, model: nil)]
        case "item.completed", "item.updated":
            guard let item = object["item"] as? [String: Any],
                  item["type"] as? String == "agent_message",
                  let text = item["text"] as? String, !text.isEmpty
            else { return [] }  // `error` items are non-fatal warnings
            state.finalText = text
            return [.message(text)]
        case "turn.completed":
            state.succeeded = true
            if let usage = object["usage"] as? [String: Any] {
                state.inputTokens = intValue(usage["input_tokens"])
                state.outputTokens = (intValue(usage["output_tokens"]) ?? 0)
                    + (intValue(usage["reasoning_output_tokens"]) ?? 0)
            }
            return []
        case "turn.failed":
            state.succeeded = false
            let error = object["error"] as? [String: Any]
            state.errorMessage = Self.unwrap(error?["message"] as? String) ?? state.errorMessage
            return []
        case "error":
            state.errorMessage = Self.unwrap(object["message"] as? String) ?? state.errorMessage
            return []
        default:
            return []
        }
    }

    /// Codex nests the provider's JSON error inside the message string
    static func unwrap(_ message: String?) -> String? {
        guard let message else { return nil }
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = (object["error"] as? [String: Any])?["message"] as? String
        else { return message }
        return inner
    }
}

// MARK: - OpenCode

public struct OpencodeSummaryAdapter: SummaryExecutorAdapter {
    public init() {}

    public var kind: SummaryExecutorKind { .opencode }
    public var streams: Bool { false }
    public var helpArguments: [String] { ["run", "--help"] }
    public var requiredFlags: [String] { ["--format", "--dir", "--pure", "--model"] }

    public func arguments(workingDirectory: String, model: String?) -> [String] {
        // OpenCode has no ephemeral mode: the run is recorded as a session whose directory is the
        // app-managed workspace, which ingestion recognizes and skips (SummaryWorkspacePaths)
        var args = ["run", "--format", "json", "--pure", "--dir", workingDirectory]
        if let model, !model.isEmpty { args += ["--model", model] }
        return args
    }

    public var extraEnvironment: [String: String] { [:] }

    public func makeParser() -> SummaryOutputParser { OpencodeJSONParser() }
}

final class OpencodeJSONParser: SummaryOutputParser {
    let state = SummaryParseState()
    private var partOrder: [String] = []
    private var parts: [String: String] = [:]

    func consume(_ object: [String: Any]) -> [SummaryExecutorEvent] {
        let part = object["part"] as? [String: Any]
        switch object["type"] as? String {
        case "step_start":
            let first = state.executorSessionId == nil
            state.executorSessionId = object["sessionID"] as? String ?? state.executorSessionId
            return first ? [.started(sessionId: state.executorSessionId, model: nil)] : []
        case "text":
            guard let part, let text = part["text"] as? String else { return [] }
            let id = part["id"] as? String ?? "part-\(partOrder.count)"
            if parts[id] == nil { partOrder.append(id) }
            parts[id] = text
            state.finalText = partOrder.compactMap { parts[$0] }.joined(separator: "\n\n")
            return [.message(state.finalText)]
        case "step_finish":
            if let tokens = part?["tokens"] as? [String: Any] {
                let cache = tokens["cache"] as? [String: Any]
                state.inputTokens = (state.inputTokens ?? 0) + (intValue(tokens["input"]) ?? 0)
                    + (intValue(cache?["read"]) ?? 0) + (intValue(cache?["write"]) ?? 0)
                state.outputTokens = (state.outputTokens ?? 0) + (intValue(tokens["output"]) ?? 0)
                    + (intValue(tokens["reasoning"]) ?? 0)
            }
            // "tool-calls" means another step follows; any other reason ends the run
            let reason = part?["reason"] as? String ?? "stop"
            state.succeeded = state.errorMessage == nil && reason != "tool-calls" && reason != "error"
            return []
        case "error":
            let error = object["error"] as? [String: Any]
            let data = error?["data"] as? [String: Any]
            state.errorMessage = data?["message"] as? String ?? error?["name"] as? String ?? "error"
            state.succeeded = false
            return []
        default:
            return []
        }
    }
}

public enum SummaryAdapters {
    public static func adapter(
        for kind: SummaryExecutorKind, codexMCPServers: [String] = []
    ) -> SummaryExecutorAdapter {
        switch kind {
        case .claude: return ClaudeSummaryAdapter()
        case .codex: return CodexSummaryAdapter(mcpServerNames: codexMCPServers)
        case .opencode: return OpencodeSummaryAdapter()
        }
    }
}
