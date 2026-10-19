import Foundation
import EurekaKit

/// Envelope format of event files in the spool directory (matches eureka-relay's JSON output
/// contract; the relay is a zero-dependency target, so no code is shared, only this contract):
///
/// ```json
/// {
///   "v": 1,
///   "channel": "claude-hook" | "codex-notify" | "inject",
///   "receivedAtMs": 1718000000123,
///   "terminal": { "app": …, "bundleId": …, "tty": …, "tmuxPane": … },  // optional
///   "payload": { ...raw hook stdin / notify argv JSON... }
/// }
/// ```
///
/// `terminal` is an **envelope-level** field (not inside payload): it describes the terminal the
/// relay invocation ran in, not what the hook reported. Files written by older relays lack the key
/// → decodes to nil, backward compatible.
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
