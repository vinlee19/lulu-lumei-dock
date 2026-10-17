import Foundation

/// Parses the per-model `limit.context` from ZCode's `~/.zcode/v2/config.json` (the authoritative
/// ctx% denominator: a model catalog ZCode maintains itself, updated with client versions, more
/// accurate than the built-in table's model limits). Shape: `{ "provider": { "<providerId>": {
/// "models": { "<model>": { "limit": { "context": N } } } } } }` The same model may appear under
/// several providers (builtin:zai / *-coding-plan / custom) with the same value; when they differ,
/// take the max (a custom provider configured with a larger window wins). Keys are matched
/// lowercased (rollout records "glm-5.3", config writes "GLM-5.3"). A missing / malformed file
/// returns an empty map, never throws.
public enum ZcodeConfigWindows {
    public static func parse(configURL: URL) -> [String: Int] {
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let providers = root["provider"] as? [String: Any]
        else { return [:] }
        var map: [String: Int] = [:]
        for provider in providers.values {
            guard let models = (provider as? [String: Any])?["models"] as? [String: Any]
            else { continue }
            for (name, spec) in models {
                guard let limit = (spec as? [String: Any])?["limit"] as? [String: Any],
                      let context = limit["context"] as? Int, context > 0
                else { continue }
                let key = name.lowercased()
                map[key] = max(map[key] ?? 0, context)
            }
        }
        return map
    }

    /// For the session detail card / tailer: look up the window by model name
    /// (case-insensitive; returns nil when unknown, and the caller decides whether to emit
    /// contextUpdate)
    public static func window(
        forModel model: String?,
        configURL: URL = ZcodePaths.modelConfig()
    ) -> Int? {
        guard let model, !model.isEmpty else { return nil }
        return parse(configURL: configURL)[model.lowercased()]
    }
}
