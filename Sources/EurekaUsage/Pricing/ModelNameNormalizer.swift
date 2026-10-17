import Foundation

/// Expands the model name each agent stored into a set of candidate keys for price-catalog lookup.
/// The original name always comes first (names like `hy3-free` and `glm-5-2-260617` are listed
/// verbatim in the catalogs).
public enum ModelNameNormalizer {
    /// Prefixes never split off as a provider: `cursor/xxx` is Cursor's own alias, not
    /// provider/model
    static let unsplittablePrefixes = ["cursor/"]

    /// `kimi-code/k3` → ("kimi-code", "k3"); `gpt-5.6-sol` → (nil, "gpt-5.6-sol")
    public static func split(_ model: String) -> (provider: String?, model: String) {
        let lower = model.lowercased()
        if unsplittablePrefixes.contains(where: lower.hasPrefix) { return (nil, lower) }
        guard let slash = lower.lastIndex(of: "/") else { return (nil, lower) }
        let provider = String(lower[..<slash])
        let bare = String(lower[lower.index(after: slash)...])
        guard !provider.isEmpty, !bare.isEmpty else { return (nil, lower) }
        return (provider, bare)
    }

    /// Ordered, deduplicated candidate names (all lowercase)
    public static func candidates(_ model: String) -> [String] {
        var out: [String] = []
        func add(_ value: String) {
            guard !value.isEmpty, !out.contains(value) else { return }
            out.append(value)
        }
        let base = model.lowercased()
        add(base)
        // Date suffixes: -20251001 / -260617 / -2026-04-23
        let undated = replacing(base, #"-(\d{8}|\d{6}|\d{4}-\d{2}-\d{2})$"#, with: "")
        add(undated)
        // Tier / variant suffixes can stack (claude-4.5-opus-high-thinking); strip them one layer
        // at a time
        var stripped = undated
        while true {
            let next = replacing(
                stripped, #"-(thinking|high|low|medium|max|free|latest|preview|build|\d+k|\d+m)$"#,
                with: "")
            guard next != stripped else { break }
            stripped = next
            add(stripped)
        }
        // Swap dots and dashes in version numbers: glm-5-2 → glm-5.2, claude-opus-4-8 ↔
        // claude-opus-4.8
        for name in out {
            add(replacing(name, #"(\D)-(\d+)-(\d+)"#, with: "$1-$2.$3"))
            add(replacing(name, #"(\d+)\.(\d+)"#, with: "$1-$2"))
        }
        // Kimi's own CLI abbreviates kimi-k3 to k3
        for name in out where name.range(of: #"^k\d"#, options: .regularExpression) != nil {
            add("kimi-" + name)
        }
        return out
    }

    private static func replacing(_ value: String, _ pattern: String, with template: String) -> String {
        value.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
