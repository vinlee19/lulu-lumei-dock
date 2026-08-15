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
            // grok transcript 无 per-request token（订阅制不记账）-> 无真实总量
            return nil
        case .zcode:
            // zcode 的 transcriptPath 是共享 sqlite 库；真实 usage 在逐会话 rollout 文件里，
            // 调用方改用 lastZcodeContext(rolloutPath:)（顺带带回模型名给窗口分母查询）
            return nil
        }
    }

    /// zcode：rollout（`model-io-sess_<id>.jsonl`）末条 `response.usage` 的
    /// inputTokens + outputTokens（OpenAI 口径：inputTokens 已含缓存读，两者之和
    /// = 文件自带 totalTokens = 官方「上下文容量」分子）。模型名一并带回
    /// （model.modelId 与 response.modelId 值等价、统一小写），供 v2/config.json
    /// 查窗口分母——不依赖账本行，账本 60s tick 未到时分母也能查对。
    ///
    /// ⚠️ 不能走 readTail/逐行 JSON：zcode 每行内嵌完整 `request.body.messages`
    /// （实测单行 25 万~47 万字节，64KB 尾窗连一根完整行都盖不住）。改为从尾部
    /// 按块回退（256KB 起、×4 递增、上限 16MB），字节级找最后一个结构性
    /// `"usage":{"inputTokens":` 片段——JSON 字符串里的引号必被转义，裸片段
    /// 只可能是真实结构，不会误中对话正文。
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

    /// 字节块里从后往前找 usage 片段并解析（平铺对象，到第一个 `}` 截断）
    static func lastZcodeUsageSnippet(in data: Data) -> (model: String?, tokens: Int)? {
        let marker = Data("\"usage\":{\"inputTokens\":".utf8)
        var searchUpper = data.endIndex
        while searchUpper > data.startIndex,
              let range = data.range(
                of: marker, options: .backwards, in: data.startIndex..<searchUpper) {
            searchUpper = range.lowerBound
            let objectStart = range.lowerBound + "\"usage\":".utf8.count  // 落在 `{`
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

    /// 块内最后一个 `"modelId":"…"`（model.modelId 大写 / response.modelId 小写，
    /// 值等价，取哪个都一样；进行中的新行无 usage 但有 model，同会话同模型，无害）
    private static func lastZcodeModelId(in data: Data) -> String? {
        let marker = Data("\"modelId\":\"".utf8)
        guard let range = data.range(of: marker, options: .backwards),
              let quote = data[range.upperBound...].firstIndex(of: UInt8(ascii: "\"")),
              quote > range.upperBound
        else { return nil }
        return String(decoding: data[range.upperBound..<quote], as: UTF8.self).lowercased()
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
