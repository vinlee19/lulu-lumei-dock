import EurekaKit
import Foundation

/// Result of one price resolution: price + provenance (for the hover tooltip and the
/// "unpriced/estimated" list)
public struct PriceResolution: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case override             // user pricing.json
        case litellm              // LiteLLM catalog
        case modelsDev(String)    // a models.dev provider
        case bundled              // bundled handwritten table
        case reported             // cost self-reported by the agent (Grok costUsdTicks)
    }

    /// nil = unpriced (show tokens only, no cost)
    public var price: ModelPrice?
    public var source: Source?
    /// The catalog key that matched (e.g. `gpt-6-sol`, `zai/glm-5.2`, a handwritten-table prefix)
    public var matchedKey: String?
    /// Handwritten-table prefix fallback (not an exact match); the numbers may be off
    public var estimated: Bool = false
    /// Subscription plan: API-equivalent cost at the vendor's pay-as-you-go price, not an actual
    /// charge
    public var subscription: Bool = false
    /// provider is a user-defined name (unknown to the catalogs and the alias table); vendor
    /// inferred from the model name
    public var vendorInferred: Bool = false

    public static let unpriced = PriceResolution(price: nil, source: nil)

    /// One-line human-readable provenance (for the dashboard hover)
    public var summary: String {
        guard price != nil, let source else { return L10n.text("Unpriced", zhHans: "未定价") }
        var parts: [String] = []
        switch source {
        case .override: parts.append(L10n.text("Custom price", zhHans: "自定义价格"))
        case .litellm: parts.append("LiteLLM")
        case .modelsDev(let provider): parts.append("models.dev/\(provider)")
        case .bundled: parts.append(estimated ? L10n.text("Bundled price (estimated)", zhHans: "内置价格（估算）") : L10n.text("Bundled price", zhHans: "内置价格"))
        case .reported: parts.append(L10n.text("Agent-reported cost", zhHans: "agent 自报费用"))
        }
        if let matchedKey { parts.append(matchedKey) }
        var text = parts.joined(separator: " · ")
        if subscription { text += L10n.text(" (subscription · API-equivalent price)", zhHans: "（订阅 · API 等价价）") }
        if vendorInferred { text += L10n.text(" (vendor inferred from model name)", zhHans: "（按模型名推断厂商）") }
        return text
    }
}

/// Price resolution: user override -> hard-unpriced -> provider hint -> LiteLLM exact -> by vendor
/// -> handwritten exact -> handwritten prefix -> unpriced. Pure function, no IO; PricingTable wraps
/// it with a cache keyed by (model, provider).
public struct PriceResolver: Sendable {
    /// User overrides (sorted longest prefix first); unknown is authoritative here
    let overrides: [ModelPrice]
    /// Bundled handwritten table (sorted longest prefix first)
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

        // 1. User override: keeps the old semantics (model-name prefix, longest wins, unknown
        //    blocks)
        if let hit = overrides.first(where: { lowerModel.hasPrefix($0.match.lowercased()) }) {
            guard hit.isPriced else { return .unpriced }
            return PriceResolution(price: hit, source: .override, matchedKey: hit.match)
        }
        // 2. Hard-unpriced (cursor/: Cursor bills on its own; the model name is just its alias)
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

        // 3. Provider hint: trust its price only when it is a "third-party host" (a vendor's own id
        //    is left to 4/5, so LiteLLM wins); a subscription plan's $0 price is not trusted
        if let hint {
            let isVendorItself = vendor?.modelsDevIds.contains(hint) == true
            if let from = alias?.priceFrom, let host = catalog.modelsDev[from], !host.subscription,
               let (key, price) = lookup(candidates, in: host.models) {
                return found(price, .modelsDev(from), key)
            }
            // Aggregator keys often carry a vendor segment (openrouter's
            // `deepseek/deepseek-v4.1-flash`); last-segment match as fallback
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
        // 4. LiteLLM bare-key exact match (same source as ccusage; it wins when the two disagree)
        if let (key, price) = lookup(candidates, in: catalog.litellm) {
            return found(price, .litellm, key)
        }
        // 5. By vendor family: official models.dev provider -> LiteLLM `<vendor>/` keys (never
        // falls through to resellers)
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
        // 6. Handwritten table exact match
        for candidate in [lowerModel] + candidates {
            if let hit = bundled.first(where: { $0.match.lowercased() == candidate }) {
                guard hit.isPriced else { return .unpriced }
                return PriceResolution(
                    price: hit, source: .bundled, matchedKey: hit.match,
                    subscription: subscription, vendorInferred: vendorInferred)
            }
        }
        // 7. Handwritten-table prefix fallback: an unknown sentinel blocks shorter prefixes; a hit
        // is flagged "estimated"
        if let hit = bundled.first(where: { lowerModel.hasPrefix($0.match.lowercased()) }) {
            guard hit.isPriced else { return .unpriced }
            return PriceResolution(
                price: hit, source: .bundled, matchedKey: hit.match, estimated: true,
                subscription: subscription, vendorInferred: vendorInferred)
        }
        return .unpriced
    }

    /// Key starts with prefix and its last segment equals a candidate (first by candidate order,
    /// then key order, so the result is stable)
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
