import Foundation
import EurekaKit
import EurekaStore

/// 模型定价（USD / 百万 token）。
/// `unknown: true` 是显式"未定价"哨兵：阻断更短前缀的家族回退，避免静默算错钱。
/// 手写表里的 unknown 默认是“软”的——远程价格目录查得到就用目录价；
/// `authoritative: true` 的（如 `cursor/`）才是硬性不算钱。用户覆盖文件里的 unknown 一律权威。
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

    /// 有输入/输出价且非 unknown 哨兵
    public var isPriced: Bool {
        unknown != true && inputPerM != nil && outputPerM != nil
    }
}

/// 价格表文件（随包 pricing.json 与用户覆盖文件同结构）：`models` 前缀表 + 可选 `providers` 别名表
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

/// 价格表：PriceResolver 外包一层按 (model, provider) 的解析缓存。
/// 值语义、可跨线程共享；换一份价格目录就是换一个新 PricingTable，缓存随之失效。
public struct PricingTable: Sendable {
    public let resolver: PriceResolver
    private let memo = ResolutionMemo()

    public init(resolver: PriceResolver) {
        self.resolver = resolver
    }

    /// 仅手写表（无远程目录、无覆盖）：测试与兜底用，语义同旧版
    public init(models: [ModelPrice]) {
        self.init(resolver: PriceResolver(bundled: models))
    }

    public init(data: Data) throws {
        let file = try PricingFile.decode(data)
        self.init(resolver: PriceResolver(bundled: file.models, aliases: file.providers ?? [:]))
    }

    /// 随包手写表 + 用户覆盖文件（最上层，不再整表替换）+ 远程价格目录
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

    /// 只按模型名解析（无 provider 信息时）；nil = 未定价
    public func price(for model: String) -> ModelPrice? {
        resolution(for: model, provider: nil).price
    }

    public func resolution(for model: String, provider: String?) -> PriceResolution {
        let key = provider.map { "\(model)\u{1}\($0)" } ?? model
        if let cached = memo.get(key) { return cached }
        let result = resolver.resolve(model: model, provider: provider)
        memo.set(key, result)
        return result
    }

    /// 一组聚合的费用；nil = 该模型未定价
    public func cost(of totals: UsageTotals) -> Double? {
        guard let price = resolution(for: totals.model, provider: totals.provider).price else {
            return nil
        }
        return Self.cost(of: totals, price: price)
    }

    static func cost(of totals: UsageTotals, price: ModelPrice) -> Double? {
        guard let inputPerM = price.inputPerM, let outputPerM = price.outputPerM else { return nil }

        // 缓存价缺省时按 Anthropic 惯例从输入价推导：读 0.1x、5m 写 1.25x、1h 写 2x（显式 0 就是 0）
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

/// 解析结果缓存：看板每次渲染都会逐行算钱（主线程），扫描在后台队列，故加锁
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
