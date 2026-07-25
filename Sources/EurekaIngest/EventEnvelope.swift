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
///   "terminal": { "app": …, "bundleId": …, "tty": …, "tmuxPane": … },  // 可选
///   "payload": { ...原始 hook stdin / notify argv JSON... }
/// }
/// ```
///
/// `terminal` 是**信封层**字段（不在 payload 里）：它描述 relay 那次调用所处的终端，
/// 而不是 hook 报告的内容。旧版 relay 写的文件没有这个键 → 解出 nil，向后兼容。
public struct RawEvent {
    public var channel: String
    public var receivedAt: Date
    public var payload: [String: Any]
    public var terminal: TerminalBinding?

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
        self.terminal = Self.decodeTerminal(dict["terminal"])
    }

    static func decodeTerminal(_ raw: Any?) -> TerminalBinding? {
        guard let dict = raw as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            guard let value = dict[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        let binding = TerminalBinding(
            app: string("app"), bundleId: string("bundleId"),
            tty: string("tty"), tmuxPane: string("tmuxPane"), origin: .hook)
        return binding.isEmpty ? nil : binding
    }
}
