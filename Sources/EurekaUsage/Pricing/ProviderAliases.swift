import Foundation

/// Provider aliases: map the assorted provider ids used across agents (including user-defined
/// names) to vendors the price catalogs know, and flag subscription plans. Subscription plans are
/// priced at the vendor's pay-as-you-go rate as an **API-equivalent cost**.
public struct ProviderAlias: Codable, Equatable, Sendable {
    public enum Billing: String, Codable, Sendable {
        case payg          // Pay-as-you-go: the provider's catalog price can be trusted directly
        case subscription  // Subscription plan: catalog price is 0, so convert at the vendor's pay-as-you-go rate
    }

    /// Model vendor (VendorFamily.id); nil = infer from the model name only
    public var vendor: String?
    public var billing: Billing
    /// models.dev provider to take prices from explicitly (e.g. models hosted on Volcengine Ark
    /// take volcengine's price)
    public var priceFrom: String?

    public init(vendor: String? = nil, billing: Billing = .payg, priceFrom: String? = nil) {
        self.vendor = vendor
        self.billing = billing
        self.priceFrom = priceFrom
    }
}

/// Model vendor: identifies the family by model-name prefix, then takes prices under that vendor's
/// official ids in both catalogs
public struct VendorFamily: Sendable {
    public let id: String
    /// Model-name prefixes (lowercase, matched in order)
    let modelPrefixes: [String]
    /// The vendor's official provider ids on models.dev (in priority order)
    let modelsDevIds: [String]
    /// The vendor's key prefix in LiteLLM (without the slash)
    let litellmPrefixes: [String]
}

public enum ProviderCatalog {
    /// Built-in aliases (lowercase keys). `providers` in the user's pricing.json can
    /// override/extend them.
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

    /// Resellers / aggregators: their prices differ widely from official ones (the same glm-5.2
    /// ranges from $0.3 to $1.8), so they are trusted only when the user explicitly goes through
    /// them (the provider hint is that reseller)
    public static let resellers: Set<String> = [
        "openrouter", "qiniu-ai", "poe", "orcarouter", "aihubmix", "vercel", "vercel_ai_gateway",
        "fireworks-ai", "fireworks_ai", "together_ai", "togetherai", "replicate", "azure_ai",
        "nano-gpt", "requesty", "llmgateway", "llmgateway-providers", "zenmux", "302ai",
        "novita", "novita-ai", "deepinfra", "siliconflow", "siliconflow-cn", "cloudflare",
    ]

    public static func vendor(id: String) -> VendorFamily? {
        vendors.first { $0.id == id }
    }

    /// Identifies the vendor by model name (any candidate name matching a prefix is enough)
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
