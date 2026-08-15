import Foundation

/// ZCode `~/.zcode/v2/config.json` 的 per-model `limit.context` 解析（ctx% 分母的
/// 权威来源：ZCode 自己维护的模型目录，随客户端版本更新，比内建表的模型上限更准）。
/// 结构：`{ "provider": { "<providerId>": { "models": { "<型号>": { "limit": { "context": N } } } } } }`
/// 同一型号可能出现在多个 provider（builtin:zai / *-coding-plan / 自定义）下且值一致；
/// 不一致时取最大（自定义 provider 配了大窗口以它为准）。键统一小写匹配
/// （rollout 记 "glm-5.3"、config 写 "GLM-5.3"）。文件缺失/格式异常返回空表，不抛错。
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

    /// 会话详情卡片 / tailer 用：按模型名查窗口（大小写不敏感；无记录返回 nil，
    /// 调用方决定是否发 contextUpdate）
    public static func window(
        forModel model: String?,
        configURL: URL = ZcodePaths.modelConfig()
    ) -> Int? {
        guard let model, !model.isEmpty else { return nil }
        return parse(configURL: configURL)[model.lowercased()]
    }
}
