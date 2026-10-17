import EurekaKit
import Foundation

/// Reads the real context size of the last turn: reads only the transcript tail (64KB by default)
/// and extracts, per source, the input-side tokens of the last usage entry (~ the context size that
/// triggered that turn). Best-effort throughout: any format mismatch or parse failure returns nil;
/// **never throws**.
public enum LastTurnUsageReader {
    /// Bytes scanned from the tail: a usage line is small, so 64KB covers several trailing turns
    public static let tailBytes = 65_536

    /// Reads this session's last-turn context size; nil when unavailable (unsupported source / no
    /// usage in the file). opencode / cursor / hermes (SQLite sources) and trae / antigravity (no
    /// message bodies) return nil outright. Takes primitive parameters rather than
    /// AgentSessionInfo: EurekaUsage does not depend on EurekaIngest.
    public static func lastContextTokens(source: AgentSource, transcriptPath: String) -> Int? {
        switch source {
        case .opencode, .cursor, .hermes, .trae, .antigravity:
            return nil
        case .claude, .qoder:
            // qoder uses a Claude-style envelope; its usage format is the same (when present)
            return lastClaudeUsage(path: transcriptPath)
        case .kimi:
            return lastKimiUsage(path: transcriptPath)
        case .codex:
            return lastCodexUsage(path: transcriptPath)
        case .gemini:
            return lastGeminiUsage(path: transcriptPath)
        case .qwen:
            return lastQwenUsage(path: transcriptPath)
        case .codebuddy:
            return lastCodeBuddyUsage(path: transcriptPath)
        case .grok:
            // grok's updates.jsonl only has per-turn totals (the sum of several model calls in a
            // turn), not the context size of a single call
            return nil
        case .zcode:
            // zcode's transcriptPath is a shared sqlite DB; the real usage lives in per-session
            // rollout files, so callers use lastZcodeContext(rolloutPath:) instead (which also
            // returns the model name for the window-denominator lookup)
            return nil
        }
    }

    /// zcode: inputTokens + outputTokens of the last `response.usage` in the rollout
    /// (`model-io-sess_<id>.jsonl`) (OpenAI semantics: inputTokens already includes cache reads;
    /// the sum = the file's own totalTokens = the numerator of the official "context capacity").
    /// Also returns the model name (model.modelId and response.modelId are equivalent, normalized
    /// to lowercase) for looking up the window denominator in v2/config.json -- independent of
    /// ledger rows, so the denominator is right even before the 60s ledger tick.
    ///
    /// WARNING: can't use readTail / per-line JSON: every zcode line embeds the full
    /// `request.body.messages` (measured 250k-470k bytes per line; a 64KB tail window can't hold
    /// even one whole line). Instead it walks back from the tail in chunks (starting at 256KB, x4
    /// each step, capped at 16MB) and finds, at the byte level, the last structural
    /// `"usage":{"inputTokens":` fragment -- quotes inside JSON strings are always escaped, so a
    /// bare fragment can only be real structure and never matches conversation text.
    public static func lastZcodeContext(rolloutPath: String) -> (model: String?, tokens: Int)? {
        guard let handle = FileHandle(forReadingAtPath: rolloutPath) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        var window: UInt64 = 256 * 1024
        let maxWindow: UInt64 = 16 * 1024 * 1024
        while true {
            let length = min(window, size)
            guard (try? handle.seek(toOffset: size - length)) != nil,
                  let data = try? handle.read(upToCount: Int(length))
            else { return nil }
            if let hit = lastZcodeUsageSnippet(in: data) { return hit }
            if length == size || window >= maxWindow { return nil }
            window *= 4
        }
    }

    /// Searches the byte chunk backwards for the usage fragment and parses it (flat object, cut at
    /// the first `}`)
    static func lastZcodeUsageSnippet(in data: Data) -> (model: String?, tokens: Int)? {
        let marker = Data("\"usage\":{\"inputTokens\":".utf8)
        var searchUpper = data.endIndex
        while searchUpper > data.startIndex,
              let range = data.range(
                of: marker, options: .backwards, in: data.startIndex..<searchUpper) {
            searchUpper = range.lowerBound
            let objectStart = range.lowerBound + "\"usage\":".utf8.count  // lands on `{`
            guard let close = data[objectStart...].firstIndex(of: UInt8(ascii: "}")),
                  let dict = (try? JSONSerialization.jsonObject(
                    with: data[objectStart...close])) as? [String: Any],
                  let input = dict["inputTokens"] as? Int, input > 0
            else { continue }
            let output = dict["outputTokens"] as? Int ?? 0
            return (lastZcodeModelId(in: data), input + output)
        }
        return nil
    }

    /// Last `"modelId":"..."` in the chunk (model.modelId is uppercase / response.modelId
    /// lowercase; the values are equivalent, so either works; an in-progress new line has a model
    /// but no usage -- same session, same model, harmless)
    private static func lastZcodeModelId(in data: Data) -> String? {
        let marker = Data("\"modelId\":\"".utf8)
        guard let range = data.range(of: marker, options: .backwards),
              let quote = data[range.upperBound...].firstIndex(of: UInt8(ascii: "\"")),
              quote > range.upperBound
        else { return nil }
        return String(decoding: data[range.upperBound..<quote], as: UTF8.self).lowercased()
    }

    /// Reads the **real value** of this session's model context window (a parameter carried in the
    /// session data). Currently only codex's token_count events carry `model_context_window`; every
    /// other source returns nil, and callers should fall back to Kimi config.toml (kimi) or the
    /// built-in ContextWindows table.
    public static func lastContextWindow(source: AgentSource, transcriptPath: String) -> Int? {
        guard source == .codex else { return nil }
        return lastMatch(path: transcriptPath) { root in
            guard root["type"] as? String == "event_msg",
                  let payload = root["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let window = info["model_context_window"] as? Int, window > 0
            else { return nil }
            return window
        }
    }

    // MARK: - Per-source parsing (reuses each UsageScanner's line-format semantics, input side only)

    /// Claude: input + cache_read + cache_creation from message.usage on assistant lines
    private static func lastClaudeUsage(path: String) -> Int? {
        lastMatch(path: path) { root in
            guard root["type"] as? String == "assistant",
                  let message = root["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { return nil }
            let input = usage["input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
            let total = input + cacheRead + cacheCreation
            return total > 0 ? total : nil
        }
    }

    /// Kimi: inputOther + inputCacheRead + inputCacheCreation on usage.record lines
    private static func lastKimiUsage(path: String) -> Int? {
        lastMatch(path: path) { root in
            guard root["type"] as? String == "usage.record",
                  let usage = root["usage"] as? [String: Any]
            else { return nil }
            let total = (usage["inputOther"] as? Int ?? 0)
                + (usage["inputCacheRead"] as? Int ?? 0)
                + (usage["inputCacheCreation"] as? Int ?? 0)
            return total > 0 ? total : nil
        }
    }

    /// Codex: info.last_token_usage.input_tokens on token_count events
    /// (OpenAI semantics: cached is a subset of input, so input is the whole turn's context size)
    private static func lastCodexUsage(path: String) -> Int? {
        lastMatch(path: path) { root in
            guard root["type"] as? String == "event_msg",
                  let payload = root["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any],
                  let input = last["input_tokens"] as? Int, input > 0
            else { return nil }
            return input
        }
    }

    /// Gemini: tokens.input on gemini lines (scanner semantics: rawInput includes cached)
    private static func lastGeminiUsage(path: String) -> Int? {
        lastMatch(path: path) { root in
            guard root["type"] as? String == "gemini",
                  let tokens = root["tokens"] as? [String: Any],
                  let input = (tokens["input"] as? NSNumber)?.intValue, input > 0
            else { return nil }
            return input
        }
    }

    /// Qwen: input_token_count of ui_telemetry api_response events (includes cached)
    private static func lastQwenUsage(path: String) -> Int? {
        lastMatch(path: path) { root in
            guard root["type"] as? String == "system",
                  root["subtype"] as? String == "ui_telemetry",
                  let payload = root["systemPayload"] as? [String: Any],
                  let event = payload["uiEvent"] as? [String: Any],
                  event["event.name"] as? String == "qwen-code.api_response",
                  let input = (event["input_token_count"] as? NSNumber)?.intValue, input > 0
            else { return nil }
            return input
        }
    }

    /// CodeBuddy: inputTokens from providerData.usage / message.usage (camelCase includes cache
    /// reads) or, as the snake_case fallback, input_tokens + cache_read_input_tokens
    private static func lastCodeBuddyUsage(path: String) -> Int? {
        lastMatch(path: path) { root in
            let providerData = root["providerData"] as? [String: Any]
            let message = root["message"] as? [String: Any]
            guard let usage = (providerData?["usage"] ?? message?["usage"]) as? [String: Any]
            else { return nil }
            if let input = usage["inputTokens"] as? Int, input > 0 { return input }
            let input = usage["input_tokens"] as? Int ?? 0
            let cached = usage["cache_read_input_tokens"] as? Int ?? 0
            let total = input + cached
            return total > 0 ? total : nil
        }
    }

    // MARK: - Helpers

    /// Walks the file tail line by line (newest first) and returns the first successful parse
    private static func lastMatch(
        path: String, parse: ([String: Any]) -> Int?
    ) -> Int? {
        guard let tail = readTail(path: path) else { return nil }
        for line in tail.reversed() {
            guard !line.isEmpty,
                  let root = (try? JSONSerialization.jsonObject(with: line))
                      as? [String: Any],
                  let value = parse(root)
            else { continue }
            return value
        }
        return nil
    }

    /// Reads the last tailBytes bytes of the file and splits them into lines (the first line may be
    /// truncated and is dropped)
    private static func readTail(path: String) -> [Data]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        guard size > 0 else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }  // drop the truncated partial line
        return lines.map { Data($0) }
    }
}
