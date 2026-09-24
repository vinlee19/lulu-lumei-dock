import Foundation

/// 把各 agent 入库的模型名展开成一组候选键，供价格目录查找。
/// 原名永远排第一（`hy3-free`、`glm-5-2-260617` 这类在目录里就是原样收录的）。
public enum ModelNameNormalizer {
    /// 不拆 provider 的前缀：`cursor/xxx` 是 Cursor 自己的别名，不是 provider/model
    static let unsplittablePrefixes = ["cursor/"]

    /// `kimi-code/k3` → ("kimi-code", "k3")；`gpt-5.6-sol` → (nil, "gpt-5.6-sol")
    public static func split(_ model: String) -> (provider: String?, model: String) {
        let lower = model.lowercased()
        if unsplittablePrefixes.contains(where: lower.hasPrefix) { return (nil, lower) }
        guard let slash = lower.lastIndex(of: "/") else { return (nil, lower) }
        let provider = String(lower[..<slash])
        let bare = String(lower[lower.index(after: slash)...])
        guard !provider.isEmpty, !bare.isEmpty else { return (nil, lower) }
        return (provider, bare)
    }

    /// 有序去重的候选名（均为小写）
    public static func candidates(_ model: String) -> [String] {
        var out: [String] = []
        func add(_ value: String) {
            guard !value.isEmpty, !out.contains(value) else { return }
            out.append(value)
        }
        let base = model.lowercased()
        add(base)
        // 日期后缀：-20251001 / -260617 / -2026-04-23
        let undated = replacing(base, #"-(\d{8}|\d{6}|\d{4}-\d{2}-\d{2})$"#, with: "")
        add(undated)
        // 档位 / 形态后缀可叠加（claude-4.5-opus-high-thinking），逐层剥
        var stripped = undated
        while true {
            let next = replacing(
                stripped, #"-(thinking|high|low|medium|max|free|latest|preview|build|\d+k|\d+m)$"#,
                with: "")
            guard next != stripped else { break }
            stripped = next
            add(stripped)
        }
        // 版本号点/横互转：glm-5-2 → glm-5.2，claude-opus-4-8 ↔ claude-opus-4.8
        for name in out {
            add(replacing(name, #"(\D)-(\d+)-(\d+)"#, with: "$1-$2.$3"))
            add(replacing(name, #"(\d+)\.(\d+)"#, with: "$1-$2"))
        }
        // Kimi 自家 CLI 把 kimi-k3 简写成 k3
        for name in out where name.range(of: #"^k\d"#, options: .regularExpression) != nil {
            add("kimi-" + name)
        }
        return out
    }

    private static func replacing(_ value: String, _ pattern: String, with template: String) -> String {
        value.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
