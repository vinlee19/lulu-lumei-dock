import Foundation

/// Parses per-model `max_context_size` from Kimi's `config.toml` (the authoritative ctx%
/// denominator: the window the user actually configured, which varies with subscription tier /
/// manual config and is more accurate than the model limits in the built-in table).
/// Naive line scan, no full TOML parse; a missing/malformed file returns a table with only the
/// default, never throws.
public enum KimiConfigWindows {
    /// Section headers look like `[models."kimi-code/k3"]` with `max_context_size = 1048576`
    /// inside. The returned table carries a `"*default*"`: 262144 fallback (Kimi Code's default
    /// window).
    public static func parse(configURL: URL) -> [String: Int] {
        var map: [String: Int] = ["*default*": 262_144]
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return map
        }
        var currentModel: String?
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if line.hasPrefix("[models.\""), let end = line.range(of: "\"]") {
                    currentModel = String(
                        line[line.index(line.startIndex, offsetBy: "[models.\"".count)..<end.lowerBound])
                } else {
                    currentModel = nil
                }
                continue
            }
            guard let model = currentModel, line.hasPrefix("max_context_size") else { continue }
            let parts = line.components(separatedBy: "=")
            if parts.count == 2,
               let value = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                map[model] = value
            }
        }
        return map
    }

    /// For the session detail card: looks up the user-configured window by model alias (falls back
    /// to Kimi Code's default 256K).
    public static func window(
        forModel model: String?,
        configURL: URL = KimiPaths.configToml()
    ) -> Int? {
        guard let model else { return nil }
        let map = parse(configURL: configURL)
        return map[model] ?? map["*default*"]
    }
}
