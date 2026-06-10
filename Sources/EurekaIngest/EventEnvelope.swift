import Foundation
import EurekaKit

/// spool 目录中事件文件的信封格式（与 eureka-relay 的 JSON 输出约定一致；
/// relay 为零依赖目标，不共享代码，只共享此契约）：
///
/// ```json
/// {
///   "v": 1,
///   "channel": "claude-hook" | "codex-notify" | "inject",
///   "receivedAtMs": 1718000000123,
///   "payload": { ...原始 hook stdin / notify argv JSON... }
/// }
/// ```
public struct RawEvent {
    public var channel: String
    public var receivedAt: Date
    public var payload: [String: Any]

    public init?(data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any],
            let channel = dict["channel"] as? String,
            let receivedAtMs = dict["receivedAtMs"] as? Double,
            let payload = dict["payload"] as? [String: Any]
        else { return nil }
        self.channel = channel
        self.receivedAt = Date(timeIntervalSince1970: receivedAtMs / 1000)
        self.payload = payload
    }
}
