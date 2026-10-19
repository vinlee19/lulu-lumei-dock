import Foundation

/// Per-model context-window size (the denominator for ctx% warnings).
/// Built-in table uses prefix matching (longest first); overrides can replace/extend it
/// (injected at app launch from ~/Library/Application Support/Eureka/context-windows.json,
/// written once at launch and read-only afterwards).
public enum ContextWindows {
    public static let defaultWindow = 200_000

    static let builtin: [String: Int] = [
        // the user's main model has a 1M window
        "claude-fable": 1_000_000,
        // enterprise accounts get Opus 1M unlocked server-side (no local trace: neither settings
        // nor transcripts mark it); listing the opus-5 / opus-4-8 the user actually runs; older
        // opus (4-1 etc., standard 200K tier) stays out of the table
        "claude-opus-5": 1_000_000,
        "claude-opus-4-8": 1_000_000,
        // Seen running past 200K on the same account, so they are on the 1M window too
        "claude-opus-4-7": 1_000_000,
        "claude-sonnet-5-5": 1_000_000,
        // Gemini 2.5/3: officially 1M across the line (prefix match, so gemini-3-pro etc. also hit)
        "gemini-2.5": 1_000_000,
        "gemini-3": 1_000_000,
        // Kimi K3: official max 1M (platform config value 1048576); k3-256k is the 256K-tier
        // variant, hit via longest-prefix-first, so the -256k entry must coexist with the shorter
        // prefix. Note: the usable window drops with the Kimi Code subscription tier (some tiers
        // get only 256K); this records the model maximum, and users override tier differences via
        // context-windows.json.
        "kimi-code/k3-256k": 262_144,
        "kimi-k3-256k": 262_144,
        "k3-256k": 262_144,
        "kimi-code/k3": 1_048_576,
        "kimi-k3": 1_048_576,
        "k3": 1_048_576,
        // Kimi K2 line (k2.5/k2.6/k2.7-code/k2-thinking etc.): officially 256K (262144)
        "kimi-code/k2": 262_144,
        "kimi-k2": 262_144,
        // glm/qwen etc. have no official figure yet and are deliberately left out; they fall to
        // defaultWindow until official data exists
    ]

    /// User overrides: {"claude-opus-4-8": 1000000, ...}
    public static var overrides: [String: Int] = [:]

    /// Window sizes models commonly ship with, ascending. Only consulted when observed usage has
    /// already passed the listed window.
    static let largerTiers = [262_144, 400_000, 1_000_000, 2_000_000]

    /// Context window for `model`. `observed` is a real context size seen for this session: a
    /// model cannot hold more than its window, so usage past the listed value proves the table is
    /// wrong for this model or account, and the window steps up instead of reporting over 100%.
    /// Claude only ships 200K and 1M windows; other models take the smallest common tier that
    /// holds the usage (erring towards a fuller gauge, never an emptier one).
    public static func window(forModel model: String?, observed: Int? = nil) -> Int {
        let listed = listedWindow(forModel: model)
        guard let observed, observed > listed else { return listed }
        if model?.hasPrefix("claude-") == true, observed <= 1_000_000 { return 1_000_000 }
        return largerTiers.first { $0 >= observed } ?? observed
    }

    public static func percent(used: Int, model: String?) -> Double {
        Double(used) / Double(window(forModel: model, observed: used)) * 100
    }

    private static func listedWindow(forModel model: String?) -> Int {
        guard let model else { return defaultWindow }
        let merged = builtin.merging(overrides) { _, user in user }
        let hit = merged.keys
            .filter { model.hasPrefix($0) }
            .max { $0.count < $1.count }
        return hit.flatMap { merged[$0] } ?? defaultWindow
    }

    /// Load the override file (missing / malformed is skipped silently)
    public static func loadOverrides(from url: URL) {
        guard
            let data = try? Data(contentsOf: url),
            let parsed = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return }
        overrides = parsed
    }
}
