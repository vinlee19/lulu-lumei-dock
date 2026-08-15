import EurekaKit
import Foundation

/// 最后一轮真实 context 总量读取器：只读 transcript 文件尾部（默认 64KB），
/// 按源提取最后一条 usage 的输入侧 token（≈触发该轮时的上下文规模）。
/// 全程 best-effort：任何格式不符/解析失败一律返回 nil，**永不抛错**。
public enum LastTurnUsageReader {
    /// 尾部扫描字节数：单行 usage 很小，64KB 足够覆盖末尾多轮
    public static let tailBytes = 65_536

    /// 读取该会话最后一轮的 context 总量；拿不到（源不支持/文件无 usage）返回 nil。
    /// opencode / cursor / hermes（SQLite 源）与 trae / antigravity（正文不可得）直接 nil。
    /// 入参为基本类型而非 AgentSessionInfo：EurekaUsage 不依赖 EurekaIngest。
    public static func lastContextTokens(source: AgentSource, transcriptPath: String) -> Int? {
        switch source {
        case .opencode, .cursor, .hermes, .trae, .antigravity:
            return nil
        case .claude, .qoder:
            // qoder 是 Claude 式信封，usage 格式相同（若有）
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
            // grok transcript 无 per-request token（订阅制不记账）→ 无真实总量
            return nil
        }
    }

    /// 读取该会话模型上下文窗口的**真实值**（会话数据里自带的参数）。
    /// 目前只有 codex 的 token_count 事件带 `model_context_window`；其余源一律 nil，
    /// 调用方应回退到 Kimi config.toml（kimi）或 ContextWindows 内建表。
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

    // MARK: - 各源解析（复用对应 UsageScanner 的行格式口径，只取输入侧）

    /// Claude：assistant 行 message.usage 的 input + cache_read + cache_creation
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

    /// Kimi：usage.record 行的 inputOther + inputCacheRead + inputCacheCreation
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

    /// Codex：token_count 事件 info.last_token_usage.input_tokens
    /// （OpenAI 口径 cached 是 input 的子集，input 即整轮上下文规模）
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

    /// Gemini：gemini 行 tokens.input（scanner 口径：rawInput 含 cached）
    private static func lastGeminiUsage(path: String) -> Int? {
        lastMatch(path: path) { root in
            guard root["type"] as? String == "gemini",
                  let tokens = root["tokens"] as? [String: Any],
                  let input = (tokens["input"] as? NSNumber)?.intValue, input > 0
            else { return nil }
            return input
        }
    }

    /// Qwen：ui_telemetry 的 api_response 事件 input_token_count（含 cached）
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

    /// CodeBuddy：providerData.usage / message.usage 的 inputTokens（camel 含缓存读）
    /// 或 snake 兜底 input_tokens + cache_read_input_tokens
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

    // MARK: - 工具

    /// 从文件尾部逐行（倒序）找第一个命中的解析结果
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

    /// 读文件末尾 tailBytes 字节并按行切开（首行可能残缺，丢弃）
    private static func readTail(path: String) -> [Data]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        guard size > 0 else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }  // 丢弃残缺的半行
        return lines.map { Data($0) }
    }
}
