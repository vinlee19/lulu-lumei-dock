import Foundation
import EurekaKit

/// Extracts runtime info from the transcript tail in one pass:
/// - Context usage: input + cache_read + cache_creation of the latest main-chain assistant ≈
///   current context size; the window comes from the ContextWindows table by the line's model (the
///   user's main model is 1M)
/// - Session title: the latest custom-title line (Desktop auto-naming / `/rename`) → sidecar →
///   legacy ai-title, a better session name than the raw prompt (see `ClaudeSessionTitle`)
public enum ClaudeContextEstimator {

    public struct TailInfo: Equatable {
        public var contextPercent: Double?
        public var sessionTitle: String?

        public init(contextPercent: Double? = nil, sessionTitle: String? = nil) {
            self.contextPercent = contextPercent
            self.sessionTitle = sessionTitle
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
        // Back to front: the newest line of each title kind (custom-title and ai-title never
        // coexist in one file)
        var customTitle: String?
        var aiTitle: String?
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let root = object as? [String: Any],
                let type = root["type"] as? String
            else { continue }

            if let (isCustom, title) = ClaudeSessionTitle.line(root) {
                if isCustom { if customTitle == nil { customTitle = title } }
                else if aiTitle == nil { aiTitle = title }
            }

            if type == "assistant", info.contextPercent == nil,
               root["isSidechain"] as? Bool != true,
               let message = root["message"] as? [String: Any],
               let model = message["model"] as? String, model != "<synthetic>",
               let usage = message["usage"] as? [String: Any] {
                let used = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["cache_read_input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                if used > 0 {
                    info.contextPercent = ContextWindows.percent(used: used, model: model)
                }
            }

            if (customTitle != nil || aiTitle != nil) && info.contextPercent != nil { break }
        }
        info.sessionTitle = customTitle
            ?? ClaudeSessionTitle.sidecar(transcriptPath: transcriptPath)
            ?? aiTitle
        return info
    }

    /// Legacy-compatible entry point: context usage only
    public static func estimate(transcriptPath: String, tailBytes: Int = 65536) -> Double? {
        inspect(transcriptPath: transcriptPath, tailBytes: tailBytes).contextPercent
    }
}
