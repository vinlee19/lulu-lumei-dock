import Foundation

/// 远程价格目录（LiteLLM + models.dev）的规整形态：统一为 USD / 百万 token，键一律小写。
/// 纯值类型，可跨线程共享；磁盘缓存与随包快照都是它的 JSON 序列化。
public struct PriceCatalog: Codable, Equatable, Sendable {
    /// models.dev 的一个 provider：订阅套餐（coding plan 等）价格全为 0，只用于识别，不采信其价格
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

    /// 单个来源的元信息（fetchedAt 用于缓存 vs 随包快照谁新用谁；etag 用于条件请求）
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

    /// LiteLLM：原始键小写（如 `gpt-6-sol`、`zai/glm-5.2`、`openrouter/z-ai/glm-5.2`）
    public var litellm: [String: CatalogPrice]
    /// models.dev：provider id（小写）→ 模型 id（小写）→ 价格
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

    /// 逐来源取较新者合并：磁盘缓存与随包快照各自可能只有一边新（如 models.dev 拉取失败）
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

/// 目录里的单条价格（USD / 百万 token）。短键编码，控制缓存/快照体积。
/// 缓存价为 nil 表示目录未给出（按 Anthropic 惯例推导）；显式 0 就是 0。
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

/// 远程目录解析 + 校验。远程数据一律不信任：超大、结构不对、条目过少、数值异常都拒收，
/// 调用方拒收后继续用上一份缓存。
public enum PriceCatalogParser {
    /// 单来源体积上限（字节）
    public static let litellmMaxBytes = 16 << 20
    public static let modelsDevMaxBytes = 24 << 20
    /// 有效条目下限：低于此值视为源坏了（正常 LiteLLM ~3000、models.dev ~200 provider）
    public static let litellmMinEntries = 1000
    public static let modelsDevMinProviders = 50
    /// 单价上限（USD / 百万 token），超过视为脏数据
    public static let maxPricePerM: Double = 10_000
    /// LiteLLM 里有对话计价意义的 mode；embedding / image 等跳过
    static let litellmModes: Set<String> = ["chat", "responses", "completion"]

    public static func parseLiteLLM(
        _ data: Data, minEntries: Int = litellmMinEntries
    ) throws -> [String: CatalogPrice] {
        guard data.count <= litellmMaxBytes else {
            throw CatalogValidationError(message: "LiteLLM 目录超过体积上限（\(data.count) 字节）")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogValidationError(message: "LiteLLM 目录不是 JSON 对象")
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
            // 裸键但归属转售平台（together_ai 等）：改挂到 `<平台>/<键>` 下，避免被裸名当官方价命中
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
            throw CatalogValidationError(message: "models.dev 目录超过体积上限（\(data.count) 字节）")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogValidationError(message: "models.dev 目录不是 JSON 对象")
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
            // 订阅套餐：id 带 plan（coding-plan / token-plan / agent-plan…）或全部模型价格为 0
            let subscription = id.contains("plan") || prices.values.allSatisfy(\.isZero)
            result[id] = PriceCatalog.Provider(subscription: subscription, models: prices)
        }
        let total = result.values.reduce(0) { $0 + $1.models.count }
        try checkQuality(valid: total, bad: bad, min: 0, name: "models.dev")
        guard result.count >= minProviders else {
            throw CatalogValidationError(
                message: "models.dev 目录 provider 过少（\(result.count) < \(minProviders)）")
        }
        return result
    }

    /// 与上一份缓存相比条目骤减一半以上：多半是源端事故，整份拒收
    public static func checkNotCollapsed(new: Int, previous: Int?, name: String) throws {
        guard let previous, previous > 0 else { return }
        if new * 2 < previous {
            throw CatalogValidationError(message: "\(name) 条目骤减（\(previous) → \(new)），已拒收")
        }
    }

    private static func checkQuality(valid: Int, bad: Int, min: Int, name: String) throws {
        guard valid >= min else {
            throw CatalogValidationError(message: "\(name) 有效条目过少（\(valid) < \(min)）")
        }
        // 坏条目超过 5%：整体格式可能变了，宁可不用
        if bad * 20 > valid + bad {
            throw CatalogValidationError(message: "\(name) 异常条目过多（\(bad)/\(valid + bad)）")
        }
    }

    /// LiteLLM 按 token 计价 → 每百万；非数值 / 负数 / NaN / 超上限 → nil
    private static func perToken(_ value: Any?) -> Double? {
        guard let raw = number(value) else { return nil }
        return sane((raw * 1_000_000 * 1e9).rounded() / 1e9)
    }

    private static func perMillion(_ value: Any?) -> Double? {
        guard let raw = number(value) else { return nil }
        return sane(raw)
    }

    private static func number(_ value: Any?) -> Double? {
        // JSONSerialization 把 true/false 也桥接成 NSNumber，排除布尔
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
