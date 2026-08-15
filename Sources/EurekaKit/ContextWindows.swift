import Foundation

/// 各模型上下文窗口大小（ctx% 预警的分母）。
/// 内建表前缀匹配（长优先）；可被 overrides 覆盖/扩充
/// （app 启动时从 ~/Library/Application Support/Eureka/context-windows.json 注入，
/// 只在启动时写一次，之后只读）。
public enum ContextWindows {
    public static let defaultWindow = 200_000

    static let builtin: [String: Int] = [
        // 用户主力模型为 1M 窗口
        "claude-fable": 1_000_000,
        // 企业版账号服务端解锁 Opus 1M（本地无痕：settings/transcript 均无标记），
        // 按用户实况收录在用的 opus-5 / opus-4-8；旧 opus（4-1 等 200K 标准档）不落表
        "claude-opus-5": 1_000_000,
        "claude-opus-4-8": 1_000_000,
        // Gemini 2.5/3 全系官方 1M 窗口（前缀匹配，gemini-3-pro 等也能命中）
        "gemini-2.5": 1_000_000,
        "gemini-3": 1_000_000,
        // Kimi K3 官方最高 1M（平台配置值 1048576）；k3-256k 是 256K 档位变体，
        // 靠最长前缀优先命中，-256k 条目必须与短前缀同时存在。
        // 注意：实际可用窗口随 Kimi Code 订阅档位降档（部分档位仅 256K），
        // 此处记模型上限，档位差异由用户用 context-windows.json 覆盖。
        "kimi-code/k3-256k": 262_144,
        "kimi-k3-256k": 262_144,
        "k3-256k": 262_144,
        "kimi-code/k3": 1_048_576,
        "kimi-k3": 1_048_576,
        "k3": 1_048_576,
        // Kimi K2 系（k2.5/k2.6/k2.7-code/k2-thinking 等）官方均为 256K（262144）
        "kimi-code/k2": 262_144,
        "kimi-k2": 262_144,
        // glm/qwen 等暂无官方确数，刻意不收录——落到 defaultWindow，待官方数据再补
    ]

    /// 用户覆盖：{"claude-opus-4-8": 1000000, ...}
    public static var overrides: [String: Int] = [:]

    public static func window(forModel model: String?) -> Int {
        guard let model else { return defaultWindow }
        let merged = builtin.merging(overrides) { _, user in user }
        let hit = merged.keys
            .filter { model.hasPrefix($0) }
            .max { $0.count < $1.count }
        return hit.flatMap { merged[$0] } ?? defaultWindow
    }

    public static func percent(used: Int, model: String?) -> Double {
        Double(used) / Double(window(forModel: model)) * 100
    }

    /// 加载覆盖文件（不存在/格式错都安静跳过）
    public static func loadOverrides(from url: URL) {
        guard
            let data = try? Data(contentsOf: url),
            let parsed = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return }
        overrides = parsed
    }
}
