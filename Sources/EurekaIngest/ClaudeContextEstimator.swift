import Foundation

/// 从 transcript 尾部一次性提取运行期信息：
/// - 上下文占用：最近一条主链 assistant 的 input + cache_read + cache_creation
///   ≈ 当前上下文大小（窗口官方未暴露，按 200k 估，预警用足够）
/// - 会话标题：最近的 ai-title 行（Claude Code 自动生成，比原始 prompt 更适合做会话名）
public enum ClaudeContextEstimator {
    public static let assumedContextWindow = 200_000

    public struct TailInfo: Equatable {
        public var contextPercent: Double?
        public var aiTitle: String?

        public init(contextPercent: Double? = nil, aiTitle: String? = nil) {
            self.contextPercent = contextPercent
            self.aiTitle = aiTitle
        }
    }

    public static func inspect(transcriptPath: String, tailBytes: Int = 65536) -> TailInfo {
        guard
            let handle = FileHandle(forReadingAtPath: transcriptPath),
            let size = try? handle.seekToEnd()
        else { return TailInfo() }
        defer { try? handle.close() }
        let length = min(size, UInt64(tailBytes))
        guard (try? handle.seek(toOffset: size - length)) != nil,
              let data = try? handle.readToEnd()
        else { return TailInfo() }

        var info = TailInfo()
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let root = object as? [String: Any],
                let type = root["type"] as? String
            else { continue }

            if type == "ai-title", info.aiTitle == nil {
                info.aiTitle = root["aiTitle"] as? String
            }

            if type == "assistant", info.contextPercent == nil,
               root["isSidechain"] as? Bool != true,
               let message = root["message"] as? [String: Any],
               message["model"] as? String != "<synthetic>",
               let usage = message["usage"] as? [String: Any] {
                let used = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                if used > 0 {
                    info.contextPercent =
                        Double(used) / Double(assumedContextWindow) * 100
                }
            }

            if info.aiTitle != nil && info.contextPercent != nil { break }
        }
        return info
    }

    /// 兼容旧接口：仅上下文占用
    public static func estimate(transcriptPath: String, tailBytes: Int = 65536) -> Double? {
        inspect(transcriptPath: transcriptPath, tailBytes: tailBytes).contextPercent
    }
}
