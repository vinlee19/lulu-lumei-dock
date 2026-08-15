import Foundation

/// Kimi `config.toml` 的 per-model `max_context_size` 解析（ctx% 分母的权威来源：
/// 用户实际配置的窗口，随订阅档位/手动配置而变，比内建表的模型上限更准）。
/// 朴素行扫描，不解全量 TOML；文件缺失/格式异常返回仅剩默认值的表，不抛错。
public enum KimiConfigWindows {
    /// 段头形如 `[models."kimi-code/k3"]`，段内 `max_context_size = 1048576`。
    /// 返回表带 `"*default*"`: 262144 兜底（Kimi Code 默认窗口）。
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

    /// 会话详情卡片用：按模型别名查用户配置的窗口（无记录回退 Kimi Code 默认 256K）。
    public static func window(
        forModel model: String?,
        configURL: URL = KimiPaths.configToml()
    ) -> Int? {
        guard let model else { return nil }
        let map = parse(configURL: configURL)
        return map[model] ?? map["*default*"]
    }
}
