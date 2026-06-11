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
