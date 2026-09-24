import Foundation

/// provider 别名：把各 agent 里五花八门的 provider id（含用户自定义名）映射到
/// 价格目录认识的厂商，并标出是否订阅套餐。订阅套餐按厂商按量价算 **API 等价费用**。
public struct ProviderAlias: Codable, Equatable, Sendable {
    public enum Billing: String, Codable, Sendable {
        case payg          // 按量计费：可直接采信该 provider 在目录里的价格
        case subscription  // 订阅套餐：目录价为 0，改按厂商按量价折算
    }

    /// 模型厂商（VendorFamily.id），nil = 仅按模型名推断
    public var vendor: String?
    public var billing: Billing
    /// 显式指定取价的 models.dev provider（如火山方舟托管的模型取 volcengine 的价）
    public var priceFrom: String?

    public init(vendor: String? = nil, billing: Billing = .payg, priceFrom: String? = nil) {
        self.vendor = vendor
        self.billing = billing
        self.priceFrom = priceFrom
    }
}

/// 模型厂商：按模型名前缀认家族，再到该厂商在两个目录里的官方 id 下取价
public struct VendorFamily: Sendable {
    public let id: String
    /// 模型名前缀（已小写，按顺序匹配）
    let modelPrefixes: [String]
    /// models.dev 里该厂商的官方 provider id（按优先级）
    let modelsDevIds: [String]
    /// LiteLLM 里该厂商的键前缀（不含斜杠）
    let litellmPrefixes: [String]
}

public enum ProviderCatalog {
    /// 内置别名（键小写）。用户 pricing.json 的 `providers` 可覆盖/追加。
    public static let builtinAliases: [String: ProviderAlias] = [
        "openai": ProviderAlias(vendor: "openai"),
        "openai-codex": ProviderAlias(vendor: "openai", billing: .subscription),
        "anthropic": ProviderAlias(vendor: "anthropic"),
        "xai": ProviderAlias(vendor: "xai"),
        "google": ProviderAlias(vendor: "google"),
        "kimi-code": ProviderAlias(vendor: "moonshotai", billing: .subscription),
        "kimi-for-coding": ProviderAlias(vendor: "moonshotai", billing: .subscription),
        "moonshot-cn": ProviderAlias(vendor: "moonshotai", priceFrom: "moonshotai-cn"),
        "moonshotai-cn": ProviderAlias(vendor: "moonshotai", priceFrom: "moonshotai-cn"),
        "zhipuai-coding-plan": ProviderAlias(vendor: "zhipuai", billing: .subscription),
        "zai-coding-plan": ProviderAlias(vendor: "zhipuai", billing: .subscription),
        "builtin:bigmodel": ProviderAlias(vendor: "zhipuai"),
        "volcengine-agent-plan": ProviderAlias(billing: .subscription, priceFrom: "volcengine"),
        "volcengine-coding-plan": ProviderAlias(billing: .subscription, priceFrom: "volcengine"),
    ]

    public static let vendors: [VendorFamily] = [
        VendorFamily(id: "anthropic", modelPrefixes: ["claude"],
                     modelsDevIds: ["anthropic"], litellmPrefixes: ["anthropic"]),
        VendorFamily(id: "openai", modelPrefixes: ["gpt", "codex", "o1", "o3", "o4"],
                     modelsDevIds: ["openai"], litellmPrefixes: ["openai"]),
        VendorFamily(id: "google", modelPrefixes: ["gemini"],
                     modelsDevIds: ["google"], litellmPrefixes: ["gemini", "vertex_ai"]),
        VendorFamily(id: "xai", modelPrefixes: ["grok"],
                     modelsDevIds: ["xai"], litellmPrefixes: ["xai"]),
        VendorFamily(id: "zhipuai", modelPrefixes: ["glm"],
                     modelsDevIds: ["zhipuai", "zai"], litellmPrefixes: ["zai"]),
        VendorFamily(id: "moonshotai", modelPrefixes: ["kimi"],
                     modelsDevIds: ["moonshotai", "moonshotai-cn"], litellmPrefixes: ["moonshot"]),
        VendorFamily(id: "deepseek", modelPrefixes: ["deepseek"],
                     modelsDevIds: ["deepseek"], litellmPrefixes: ["deepseek"]),
        VendorFamily(id: "alibaba", modelPrefixes: ["qwen"],
                     modelsDevIds: ["alibaba", "alibaba-cn"], litellmPrefixes: ["dashscope"]),
        VendorFamily(id: "minimax", modelPrefixes: ["minimax"],
                     modelsDevIds: ["minimax", "minimax-cn"], litellmPrefixes: ["minimax"]),
        VendorFamily(id: "xiaomi", modelPrefixes: ["mimo"],
                     modelsDevIds: ["xiaomi"], litellmPrefixes: ["xiaomi"]),
        VendorFamily(id: "volcengine", modelPrefixes: ["doubao"],
                     modelsDevIds: ["volcengine"], litellmPrefixes: ["volcengine"]),
    ]

    /// 转售 / 聚合平台：报价与官方差异大（同一 glm-5.2 从 $0.3 到 $1.8），
    /// 只有用户明确走了它（provider 提示就是它）才采信
    public static let resellers: Set<String> = [
        "openrouter", "qiniu-ai", "poe", "orcarouter", "aihubmix", "vercel", "vercel_ai_gateway",
        "fireworks-ai", "fireworks_ai", "together_ai", "togetherai", "replicate", "azure_ai",
        "nano-gpt", "requesty", "llmgateway", "llmgateway-providers", "zenmux", "302ai",
        "novita", "novita-ai", "deepinfra", "siliconflow", "siliconflow-cn", "cloudflare",
    ]

    public static func vendor(id: String) -> VendorFamily? {
        vendors.first { $0.id == id }
    }

    /// 按模型名认厂商（候选名任一命中前缀即可）
    public static func vendor(forModel candidates: [String]) -> VendorFamily? {
        for name in candidates {
            if let family = vendors.first(where: { family in
                family.modelPrefixes.contains { name.hasPrefix($0) }
            }) {
                return family
            }
        }
        return nil
    }
}
