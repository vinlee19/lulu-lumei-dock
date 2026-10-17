import Foundation
import EurekaKit
import EurekaStore

/// Model pricing (USD per million tokens).
/// `unknown: true` is an explicit "unpriced" sentinel: it blocks family fallback to shorter
/// prefixes so cost is never silently wrong.
/// An unknown in the handwritten table is "soft" by default - if the remote price catalog has the
/// model, the catalog price is used;
/// only `authoritative: true` entries (e.g. `cursor/`) are hard no-cost. An unknown in the user
/// override file is always authoritative.
public struct ModelPrice: Codable, Equatable, Sendable {
    public var match: String
    public var unknown: Bool?
    public var inputPerM: Double?
    public var outputPerM: Double?
    public var cacheReadPerM: Double?
    public var cacheWrite5mPerM: Double?
    public var cacheWrite1hPerM: Double?
    public var authoritative: Bool?

    public init(
        match: String,
        unknown: Bool? = nil,
        inputPerM: Double? = nil,
        outputPerM: Double? = nil,
        cacheReadPerM: Double? = nil,
        cacheWrite5mPerM: Double? = nil,
        cacheWrite1hPerM: Double? = nil,
        authoritative: Bool? = nil
    ) {
        self.match = match
        self.unknown = unknown
        self.inputPerM = inputPerM
        self.outputPerM = outputPerM
        self.cacheReadPerM = cacheReadPerM
        self.cacheWrite5mPerM = cacheWrite5mPerM
        self.cacheWrite1hPerM = cacheWrite1hPerM
        self.authoritative = authoritative
    }

    /// Has input/output prices and is not the unknown sentinel
    public var isPriced: Bool {
        unknown != true && inputPerM != nil && outputPerM != nil
    }
}

/// Price table file (bundled pricing.json and the user override file share the shape): a `models`
/// prefix table + an optional `providers` alias table
public struct PricingFile: Codable, Sendable {
    public var models: [ModelPrice]
    public var providers: [String: ProviderAlias]?

    public init(models: [ModelPrice], providers: [String: ProviderAlias]? = nil) {
        self.models = models
        self.providers = providers
    }

    public static func decode(_ data: Data) throws -> PricingFile {
        try JSONDecoder().decode(PricingFile.self, from: data)
    }
}

/// Price table: PriceResolver wrapped with a resolution cache keyed by (model, provider).
/// Value semantics, safe to share across threads; swapping the price catalog means a new
/// PricingTable, and the cache goes with it.
public struct PricingTable: Sendable {
    public let resolver: PriceResolver
    private let memo = ResolutionMemo()

    public init(resolver: PriceResolver) {
        self.resolver = resolver
    }

    /// Handwritten table only (no remote catalog, no overrides): for tests and fallback, same
    /// semantics as the old version
    public init(models: [ModelPrice]) {
        self.init(resolver: PriceResolver(bundled: models))
    }

    public init(data: Data) throws {
        let file = try PricingFile.decode(data)
        self.init(resolver: PriceResolver(bundled: file.models, aliases: file.providers ?? [:]))
    }

    /// Bundled handwritten table + user override file (top layer, no longer replaces the whole
    /// table)
    /// + remote price catalog
    public static func load(
        bundledURL: URL?, overrideURL: URL?, catalog: PriceCatalog = .empty
    ) -> PricingTable {
        let bundled = bundledURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? PricingFile.decode($0) }
        let override = overrideURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? PricingFile.decode($0) }
        var aliases = bundled?.providers ?? [:]
        for (key, alias) in override?.providers ?? [:] { aliases[key] = alias }
        return PricingTable(resolver: PriceResolver(
            overrides: override?.models ?? [], bundled: bundled?.models ?? [],
            aliases: aliases, catalog: catalog))
    }

    /// Resolves by model name only (when there is no provider info); nil = unpriced
    public func price(for model: String) -> ModelPrice? {
        resolution(for: model, provider: nil).price
    }

    /// Price provenance for one aggregate (.reported when there is a self-reported cost)
    public func resolution(of totals: UsageTotals) -> PriceResolution {
        if totals.reportedCostUSD != nil {
            return PriceResolution(
                price: ModelPrice(match: totals.model, inputPerM: 0, outputPerM: 0),
                source: .reported, matchedKey: nil)
        }
        return resolution(for: totals.model, provider: totals.provider)
    }

    public func resolution(for model: String, provider: String?) -> PriceResolution {
        let key = provider.map { "\(model)\u{1}\($0)" } ?? model
        if let cached = memo.get(key) { return cached }
        let result = resolver.resolve(model: model, provider: provider)
        memo.set(key, result)
        return result
    }

    /// Cost of one aggregate; nil = the model is unpriced. An agent's self-reported cost (Grok)
    /// wins over the price table
    public func cost(of totals: UsageTotals) -> Double? {
        if let reported = totals.reportedCostUSD { return reported }
        guard let price = resolution(for: totals.model, provider: totals.provider).price else {
            return nil
        }
        return Self.cost(of: totals, price: price)
    }

    static func cost(of totals: UsageTotals, price: ModelPrice) -> Double? {
        guard let inputPerM = price.inputPerM, let outputPerM = price.outputPerM else { return nil }

        // Missing cache prices are derived from the input price per Anthropic convention: read
        // 0.1x, 5m write 1.25x, 1h write 2x (an explicit 0 stays 0)
        let cacheRead = price.cacheReadPerM ?? inputPerM * 0.1
        let cacheWrite5m = price.cacheWrite5mPerM ?? inputPerM * 1.25
        let cacheWrite1h = price.cacheWrite1hPerM ?? inputPerM * 2.0

        let write1h = Double(totals.cacheCreation1hTokens)
        let write5m = Double(totals.cacheCreationTokens - totals.cacheCreation1hTokens)

        let cost = Double(totals.inputTokens) * inputPerM
            + Double(totals.outputTokens) * outputPerM
            + Double(totals.cacheReadTokens) * cacheRead
            + max(0, write5m) * cacheWrite5m
            + write1h * cacheWrite1h
        return cost / 1_000_000
    }
}

/// Resolution cache: the dashboard prices every row on each render (main thread) while scans run
/// on a background queue, hence the lock
final class ResolutionMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: PriceResolution] = [:]

    func get(_ key: String) -> PriceResolution? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func set(_ key: String, _ value: PriceResolution) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }
}
