import EurekaKit
import Foundation

/// Normalized form of the remote price catalogs (LiteLLM + models.dev): unified to USD / million
/// tokens, all keys lowercase. A pure value type, safe to share across threads; the disk cache and
/// bundled snapshot are both its JSON serialization.
public struct PriceCatalog: Codable, Equatable, Sendable {
    /// One models.dev provider: subscription plans (coding plan etc.) are all priced 0, used only
    /// for identification, never trusted for price
    public struct Provider: Codable, Equatable, Sendable {
        public var subscription: Bool
        public var models: [String: CatalogPrice]

        public init(subscription: Bool, models: [String: CatalogPrice]) {
            self.subscription = subscription
            self.models = models
        }

        enum CodingKeys: String, CodingKey {
            case subscription = "sub"
            case models = "m"
        }
    }

    /// Per-source metadata (fetchedAt decides whether the cache or bundled snapshot is newer; etag
    /// is for conditional requests)
    public struct SourceMeta: Codable, Equatable, Sendable {
        public var fetchedAt: Date
        public var etag: String?
        public var lastModified: String?
        public var entryCount: Int

        public init(fetchedAt: Date, etag: String? = nil, lastModified: String? = nil, entryCount: Int) {
            self.fetchedAt = fetchedAt
            self.etag = etag
            self.lastModified = lastModified
            self.entryCount = entryCount
        }
    }

    /// LiteLLM: raw keys lowercased (e.g. `gpt-6-sol`, `zai/glm-5.2`, `openrouter/z-ai/glm-5.2`)
    public var litellm: [String: CatalogPrice]
    /// models.dev: provider id (lowercase) → model id (lowercase) → price
    public var modelsDev: [String: Provider]
    public var litellmMeta: SourceMeta?
    public var modelsDevMeta: SourceMeta?

    public init(
        litellm: [String: CatalogPrice] = [:], modelsDev: [String: Provider] = [:],
        litellmMeta: SourceMeta? = nil, modelsDevMeta: SourceMeta? = nil
    ) {
        self.litellm = litellm
        self.modelsDev = modelsDev
        self.litellmMeta = litellmMeta
        self.modelsDevMeta = modelsDevMeta
    }

    public static let empty = PriceCatalog()

    public var isEmpty: Bool { litellm.isEmpty && modelsDev.isEmpty }

    /// Merges by taking the newer side per source: the disk cache and bundled snapshot may each be
    /// newer on only one side (e.g. a failed models.dev fetch)
    public static func newest(_ a: PriceCatalog, _ b: PriceCatalog) -> PriceCatalog {
        func newer(_ x: SourceMeta?, _ y: SourceMeta?) -> Bool {
            (x?.fetchedAt ?? .distantPast) >= (y?.fetchedAt ?? .distantPast)
        }
        var result = PriceCatalog()
        let litellmFromA = !a.litellm.isEmpty && (b.litellm.isEmpty || newer(a.litellmMeta, b.litellmMeta))
        result.litellm = litellmFromA ? a.litellm : b.litellm
        result.litellmMeta = litellmFromA ? a.litellmMeta : b.litellmMeta
        let modelsDevFromA = !a.modelsDev.isEmpty
            && (b.modelsDev.isEmpty || newer(a.modelsDevMeta, b.modelsDevMeta))
        result.modelsDev = modelsDevFromA ? a.modelsDev : b.modelsDev
        result.modelsDevMeta = modelsDevFromA ? a.modelsDevMeta : b.modelsDevMeta
        return result
    }

    enum CodingKeys: String, CodingKey {
        case litellm, modelsDev, litellmMeta, modelsDevMeta
    }
}

/// A single catalog price (USD / million tokens). Short-key encoding keeps the cache/snapshot
/// small. A nil cache price means the catalog gave none (derived by Anthropic convention); an
/// explicit 0 means 0.
public struct CatalogPrice: Codable, Equatable, Sendable {
    public var inputPerM: Double
    public var outputPerM: Double
    public var cacheReadPerM: Double?
    public var cacheWrite5mPerM: Double?
    public var cacheWrite1hPerM: Double?

    public init(
        inputPerM: Double, outputPerM: Double, cacheReadPerM: Double? = nil,
        cacheWrite5mPerM: Double? = nil, cacheWrite1hPerM: Double? = nil
    ) {
        self.inputPerM = inputPerM
        self.outputPerM = outputPerM
        self.cacheReadPerM = cacheReadPerM
        self.cacheWrite5mPerM = cacheWrite5mPerM
        self.cacheWrite1hPerM = cacheWrite1hPerM
    }

    public var isZero: Bool { inputPerM == 0 && outputPerM == 0 }

    func asModelPrice(match: String) -> ModelPrice {
        ModelPrice(
            match: match, inputPerM: inputPerM, outputPerM: outputPerM,
            cacheReadPerM: cacheReadPerM, cacheWrite5mPerM: cacheWrite5mPerM,
            cacheWrite1hPerM: cacheWrite1hPerM)
    }

    enum CodingKeys: String, CodingKey {
        case inputPerM = "i"
        case outputPerM = "o"
        case cacheReadPerM = "cr"
        case cacheWrite5mPerM = "cw"
        case cacheWrite1hPerM = "cw1h"
    }
}

public struct CatalogValidationError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
}

/// Remote catalog parsing + validation. Remote data is never trusted: oversized, malformed, too few
/// entries, or abnormal values are all rejected, and on rejection the caller keeps using the
/// previous cache.
public enum PriceCatalogParser {
    /// Per-source size cap (bytes)
    public static let litellmMaxBytes = 16 << 20
    public static let modelsDevMaxBytes = 24 << 20
    /// Minimum valid entries: below this the source is considered broken (normally LiteLLM ~3000,
    /// models.dev ~200 providers)
    public static let litellmMinEntries = 1000
    public static let modelsDevMinProviders = 50
    /// Unit price cap (USD / million tokens); anything above is treated as dirty data
    public static let maxPricePerM: Double = 10_000
    /// LiteLLM modes that are meaningful for chat pricing; embedding / image etc. are skipped
    static let litellmModes: Set<String> = ["chat", "responses", "completion"]

    public static func parseLiteLLM(
        _ data: Data, minEntries: Int = litellmMinEntries
    ) throws -> [String: CatalogPrice] {
        guard data.count <= litellmMaxBytes else {
            throw CatalogValidationError(message: L10n.format("The LiteLLM catalog exceeds the size limit (%@ bytes)", zhHans: "LiteLLM 目录超过体积上限（%@ 字节）", String(data.count)))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogValidationError(message: L10n.text("The LiteLLM catalog is not a JSON object", zhHans: "LiteLLM 目录不是 JSON 对象"))
        }
        var result: [String: CatalogPrice] = [:]
        var bad = 0
        for (key, value) in root where key != "sample_spec" {
            guard let entry = value as? [String: Any] else { continue }
            if let mode = entry["mode"] as? String, !litellmModes.contains(mode) { continue }
            guard entry["input_cost_per_token"] != nil || entry["output_cost_per_token"] != nil else {
                continue
            }
            guard let input = perToken(entry["input_cost_per_token"]),
                  let output = perToken(entry["output_cost_per_token"])
            else { bad += 1; continue }
            let price = CatalogPrice(
                inputPerM: input, outputPerM: output,
                cacheReadPerM: perToken(entry["cache_read_input_token_cost"]),
                cacheWrite5mPerM: perToken(entry["cache_creation_input_token_cost"]),
                cacheWrite1hPerM: perToken(entry["cache_creation_input_token_cost_above_1hr"]))
            // Bare key that belongs to a reseller (together_ai etc.): re-file it under
            // `<platform>/<key>` so the bare name is not matched as the official price
            var lowerKey = key.lowercased()
            if !lowerKey.contains("/"),
               let host = (entry["litellm_provider"] as? String)?.lowercased(),
               ProviderCatalog.resellers.contains(host) {
                lowerKey = "\(host)/\(lowerKey)"
            }
            result[lowerKey] = price
        }
        try checkQuality(valid: result.count, bad: bad, min: minEntries, name: "LiteLLM")
        return result
    }

    public static func parseModelsDev(
        _ data: Data, minProviders: Int = modelsDevMinProviders
    ) throws -> [String: PriceCatalog.Provider] {
        guard data.count <= modelsDevMaxBytes else {
            throw CatalogValidationError(message: L10n.format("The models.dev catalog exceeds the size limit (%@ bytes)", zhHans: "models.dev 目录超过体积上限（%@ 字节）", String(data.count)))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogValidationError(message: L10n.text("The models.dev catalog is not a JSON object", zhHans: "models.dev 目录不是 JSON 对象"))
        }
        var result: [String: PriceCatalog.Provider] = [:]
        var bad = 0
        for (providerId, value) in root {
            guard let provider = value as? [String: Any],
                  let models = provider["models"] as? [String: Any]
            else { continue }
            var prices: [String: CatalogPrice] = [:]
            for (modelId, modelValue) in models {
                guard let model = modelValue as? [String: Any],
                      let cost = model["cost"] as? [String: Any]
                else { continue }
                guard let input = perMillion(cost["input"]), let output = perMillion(cost["output"]) else {
                    bad += 1
                    continue
                }
                prices[modelId.lowercased()] = CatalogPrice(
                    inputPerM: input, outputPerM: output,
                    cacheReadPerM: perMillion(cost["cache_read"]),
                    cacheWrite5mPerM: perMillion(cost["cache_write"]))
            }
            guard !prices.isEmpty else { continue }
            let id = providerId.lowercased()
            // Subscription plan: id contains plan (coding-plan / token-plan / agent-plan…) or every
            // model is priced 0
            let subscription = id.contains("plan") || prices.values.allSatisfy(\.isZero)
            result[id] = PriceCatalog.Provider(subscription: subscription, models: prices)
        }
        let total = result.values.reduce(0) { $0 + $1.models.count }
        try checkQuality(valid: total, bad: bad, min: 0, name: "models.dev")
        guard result.count >= minProviders else {
            throw CatalogValidationError(
                message: L10n.format("The models.dev catalog has too few providers (%@ < %@)", zhHans: "models.dev 目录 provider 过少（%@ < %@）", String(result.count), String(minProviders)))
        }
        return result
    }

    /// Entries dropped by more than half versus the previous cache: most likely an upstream
    /// incident, reject the whole thing
    public static func checkNotCollapsed(new: Int, previous: Int?, name: String) throws {
        guard let previous, previous > 0 else { return }
        if new * 2 < previous {
            throw CatalogValidationError(message: L10n.format("%@ entries dropped sharply (%@ → %@); rejected", zhHans: "%@ 条目骤减（%@ → %@），已拒收", String(name), String(previous), String(new)))
        }
    }

    private static func checkQuality(valid: Int, bad: Int, min: Int, name: String) throws {
        guard valid >= min else {
            throw CatalogValidationError(message: L10n.format("%@ has too few valid entries (%@ < %@)", zhHans: "%@ 有效条目过少（%@ < %@）", String(name), String(valid), String(min)))
        }
        // More than 5% bad entries: the overall format may have changed; better not to use it
        if bad * 20 > valid + bad {
            throw CatalogValidationError(message: L10n.format("%@ has too many invalid entries (%@/%@)", zhHans: "%@ 异常条目过多（%@/%@）", String(name), String(bad), String(valid + bad)))
        }
    }

    /// LiteLLM prices per token → per million; non-numeric / negative / NaN / over the cap → nil
    private static func perToken(_ value: Any?) -> Double? {
        guard let raw = number(value) else { return nil }
        return sane((raw * 1_000_000 * 1e9).rounded() / 1e9)
    }

    private static func perMillion(_ value: Any?) -> Double? {
        guard let raw = number(value) else { return nil }
        return sane(raw)
    }

    private static func number(_ value: Any?) -> Double? {
        // JSONSerialization also bridges true/false to NSNumber; exclude booleans
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number.doubleValue
    }

    private static func sane(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0, value <= maxPricePerM else { return nil }
        return value
    }
}
