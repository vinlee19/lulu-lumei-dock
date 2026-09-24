import Foundation

/// 一次价格解析的结果：价格 + 出处（供悬停提示与“未定价/估算”清单）
public struct PriceResolution: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case override             // 用户 pricing.json
        case litellm              // LiteLLM 目录
        case modelsDev(String)    // models.dev 的某个 provider
        case bundled              // 随包手写表
        case reported             // agent 自报费用（Grok costUsdTicks）
    }

    /// nil = 未定价（只显示 token，不算钱）
    public var price: ModelPrice?
    public var source: Source?
    /// 命中的目录键（如 `gpt-6-sol`、`zai/glm-5.2`、手写表的前缀）
    public var matchedKey: String?
    /// 手写表前缀兜底（非精确命中），数字可能不准
    public var estimated: Bool = false
    /// 订阅套餐：按厂商按量价折算的 API 等价费用，并非实际扣费
    public var subscription: Bool = false
    /// provider 是用户自定义名（目录与别名表都不认识），厂商按模型名推断
    public var vendorInferred: Bool = false

    public static let unpriced = PriceResolution(price: nil, source: nil)

    /// 一行人话的出处说明（看板悬停用）
    public var summary: String {
        guard price != nil, let source else { return "未定价" }
        var parts: [String] = []
        switch source {
        case .override: parts.append("自定义价格")
        case .litellm: parts.append("LiteLLM")
        case .modelsDev(let provider): parts.append("models.dev/\(provider)")
        case .bundled: parts.append(estimated ? "内置价格（估算）" : "内置价格")
        case .reported: parts.append("agent 自报费用")
        }
        if let matchedKey { parts.append(matchedKey) }
        var text = parts.joined(separator: " · ")
        if subscription { text += "（订阅 · API 等价价）" }
        if vendorInferred { text += "（按模型名推断厂商）" }
        return text
    }
}

/// 价格解析：用户覆盖 → 硬性未定价 → provider 提示 → LiteLLM 精确 → 按厂商 → 手写表精确 → 手写表前缀 → 未定价。
/// 纯函数，无 IO；由 PricingTable 包一层按 (model, provider) 缓存。
public struct PriceResolver: Sendable {
    /// 用户覆盖（已按最长前缀排序）；unknown 在这里是权威的
    let overrides: [ModelPrice]
    /// 随包手写表（已按最长前缀排序）
    let bundled: [ModelPrice]
    let aliases: [String: ProviderAlias]
    let catalog: PriceCatalog

    public init(
        overrides: [ModelPrice] = [], bundled: [ModelPrice] = [],
        aliases: [String: ProviderAlias] = [:], catalog: PriceCatalog = .empty
    ) {
        self.overrides = overrides.sorted { $0.match.count > $1.match.count }
        self.bundled = bundled.sorted { $0.match.count > $1.match.count }
        var merged = ProviderCatalog.builtinAliases
        for (key, alias) in aliases { merged[key.lowercased()] = alias }
        self.aliases = merged
        self.catalog = catalog
    }

    public func resolve(model: String, provider: String?) -> PriceResolution {
        let lowerModel = model.lowercased()

        // 1. 用户覆盖：沿用旧语义（模型名前缀、最长优先、unknown 阻断）
        if let hit = overrides.first(where: { lowerModel.hasPrefix($0.match.lowercased()) }) {
            guard hit.isPriced else { return .unpriced }
            return PriceResolution(price: hit, source: .override, matchedKey: hit.match)
        }
        // 2. 硬性未定价（cursor/：Cursor 自己计费，模型名只是它的别名）
        if bundled.contains(where: {
            $0.authoritative == true && !$0.isPriced && lowerModel.hasPrefix($0.match.lowercased())
        }) {
            return .unpriced
        }

        let (namedProvider, bareModel) = ModelNameNormalizer.split(model)
        let hint = (provider?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? namedProvider
        let candidates = ModelNameNormalizer.candidates(bareModel)
        let alias = hint.flatMap { aliases[$0] }
        let hintProvider = hint.flatMap { catalog.modelsDev[$0] }
        let subscription = alias?.billing == .subscription
            || hintProvider?.subscription == true
            || (hint?.contains("plan") ?? false)
        let vendor = alias?.vendor.flatMap(ProviderCatalog.vendor(id:))
            ?? ProviderCatalog.vendor(forModel: candidates)
        let vendorInferred = hint != nil && alias == nil && hintProvider == nil

        func found(_ price: CatalogPrice, _ source: PriceResolution.Source, _ key: String) -> PriceResolution {
            PriceResolution(
                price: price.asModelPrice(match: key), source: source, matchedKey: key,
                subscription: subscription, vendorInferred: vendorInferred)
        }

        // 3. provider 提示：只在它是“第三方托管方”时采信它的价（官方厂商自己的 id 交给 4/5，
        //    保证 LiteLLM 优先）；订阅套餐的 0 价不采信
        if let hint {
            let isVendorItself = vendor?.modelsDevIds.contains(hint) == true
            if let from = alias?.priceFrom, let host = catalog.modelsDev[from], !host.subscription,
               let (key, price) = lookup(candidates, in: host.models) {
                return found(price, .modelsDev(from), key)
            }
            // 聚合平台的键常带厂商段（openrouter 的 `deepseek/deepseek-v4.1-flash`），末段匹配兜底
            if !subscription, !isVendorItself, let host = hintProvider,
               let (key, price) = lookup(candidates, in: host.models)
                ?? lookupLastSegment(candidates, in: host.models, prefix: "") {
                return found(price, .modelsDev(hint), key)
            }
            if !subscription, !isVendorItself,
               let (key, price) = lookup(candidates.map { "\(hint)/\($0)" }, in: catalog.litellm)
                ?? lookupLastSegment(candidates, in: catalog.litellm, prefix: hint + "/") {
                return found(price, .litellm, key)
            }
        }
        // 4. LiteLLM 裸键精确命中（ccusage 同源；两家冲突时以它为准）
        if let (key, price) = lookup(candidates, in: catalog.litellm) {
            return found(price, .litellm, key)
        }
        // 5. 按厂商家族：models.dev 官方 provider → LiteLLM `<厂商>/` 键（绝不落到转售商）
        if let vendor {
            for id in vendor.modelsDevIds {
                if let host = catalog.modelsDev[id], !host.subscription,
                   let (key, price) = lookup(candidates, in: host.models) {
                    return found(price, .modelsDev(id), key)
                }
            }
            for prefix in vendor.litellmPrefixes {
                if let (key, price) = lookup(candidates.map { "\(prefix)/\($0)" }, in: catalog.litellm) {
                    return found(price, .litellm, key)
                }
            }
        }
        // 6. 手写表精确命中
        for candidate in [lowerModel] + candidates {
            if let hit = bundled.first(where: { $0.match.lowercased() == candidate }) {
                guard hit.isPriced else { return .unpriced }
                return PriceResolution(
                    price: hit, source: .bundled, matchedKey: hit.match,
                    subscription: subscription, vendorInferred: vendorInferred)
            }
        }
        // 7. 手写表前缀兜底：unknown 哨兵阻断更短前缀；命中即标“估算”
        if let hit = bundled.first(where: { lowerModel.hasPrefix($0.match.lowercased()) }) {
            guard hit.isPriced else { return .unpriced }
            return PriceResolution(
                price: hit, source: .bundled, matchedKey: hit.match, estimated: true,
                subscription: subscription, vendorInferred: vendorInferred)
        }
        return .unpriced
    }

    /// 键以 prefix 开头、且最后一段等于候选名（按候选顺序、键排序取第一个，结果稳定）
    private func lookupLastSegment(
        _ candidates: [String], in table: [String: CatalogPrice], prefix: String
    ) -> (String, CatalogPrice)? {
        let keys = table.keys.filter { $0.hasPrefix(prefix) && $0.contains("/") }.sorted()
        for candidate in candidates {
            if let key = keys.first(where: { $0.hasSuffix("/" + candidate) }), let price = table[key] {
                return (key, price)
            }
        }
        return nil
    }

    private func lookup(_ keys: [String], in table: [String: CatalogPrice]) -> (String, CatalogPrice)? {
        for key in keys {
            if let price = table[key] { return (key, price) }
        }
        return nil
    }
}
