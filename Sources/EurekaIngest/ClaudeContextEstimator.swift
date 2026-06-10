import Foundation

/// 从 transcript 尾部估算 Claude 会话的上下文占用：
/// 最近一条主链 assistant 的 input + cache_read + cache_creation ≈ 当前上下文大小。
/// 窗口大小官方未在 transcript 暴露，按 200k 估（"≈"语义，预警用足够）。
public enum ClaudeContextEstimator {
    public static let assumedContextWindow = 200_000

    public static func estimate(transcriptPath: String, tailBytes: Int = 65536) -> Double? {
        guard
            let handle = FileHandle(forReadingAtPath: transcriptPath),
            let size = try? handle.seekToEnd()
        else { return nil }
        defer { try? handle.close() }
        let length = min(size, UInt64(tailBytes))
        guard (try? handle.seek(toOffset: size - length)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }

        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let root = object as? [String: Any],
                root["type"] as? String == "assistant",
                root["isSidechain"] as? Bool != true,
                let message = root["message"] as? [String: Any],
                message["model"] as? String != "<synthetic>",
                let usage = message["usage"] as? [String: Any]
            else { continue }

            let used = (usage["input_tokens"] as? Int ?? 0)
                + (usage["cache_read_input_tokens"] as? Int ?? 0)
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            guard used > 0 else { continue }
            return Double(used) / Double(assumedContextWindow) * 100
        }
        return nil
    }
}
