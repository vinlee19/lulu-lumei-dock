import Foundation
import EurekaKit
import EurekaStore

/// 模型定价（USD / 百万 token）。
/// `unknown: true` 是显式"未定价"哨兵：阻断更短前缀的家族回退，避免静默算错钱。
public struct ModelPrice: Codable, Equatable, Sendable {
    public var match: String
    public var unknown: Bool?
    public var inputPerM: Double?
    public var outputPerM: Double?
    public var cacheReadPerM: Double?
    public var cacheWrite5mPerM: Double?
    public var cacheWrite1hPerM: Double?

    public init(
        match: String,
        unknown: Bool? = nil,
        inputPerM: Double? = nil,
        outputPerM: Double? = nil,
        cacheReadPerM: Double? = nil,
        cacheWrite5mPerM: Double? = nil,
        cacheWrite1hPerM: Double? = nil
    ) {
        self.match = match
        self.unknown = unknown
        self.inputPerM = inputPerM
        self.outputPerM = outputPerM
        self.cacheReadPerM = cacheReadPerM
        self.cacheWrite5mPerM = cacheWrite5mPerM
        self.cacheWrite1hPerM = cacheWrite1hPerM
    }
}

public struct PricingTable: Sendable {
    public private(set) var models: [ModelPrice]

    public init(models: [ModelPrice]) {
        // 最长前缀优先
        self.models = models.sorted { $0.match.count > $1.match.count }
    }

    public init(data: Data) throws {
        struct File: Codable {
            var models: [ModelPrice]
        }
        self.init(models: try JSONDecoder().decode(File.self, from: data).models)
    }

    /// bundled 默认表 + AppSupport 覆盖文件（若存在，整表替换）
    public static func load(bundledURL: URL?, overrideURL: URL?) -> PricingTable {
        if let overrideURL,
           let data = try? Data(contentsOf: overrideURL),
           let table = try? PricingTable(data: data) {
            return table
        }
        if let bundledURL,
           let data = try? Data(contentsOf: bundledURL),
           let table = try? PricingTable(data: data) {
            return table
        }
        return PricingTable(models: [])
    }

    /// 最长前缀匹配；unknown 哨兵或无匹配 → nil（仅显示 token 不算钱）
    public func price(for model: String) -> ModelPrice? {
        guard let hit = models.first(where: { model.hasPrefix($0.match) }) else { return nil }
        if hit.unknown == true || hit.inputPerM == nil || hit.outputPerM == nil { return nil }
        return hit
    }

    /// 一组聚合的费用；nil = 该模型未定价
    public func cost(of totals: UsageTotals) -> Double? {
        guard let price = price(for: totals.model),
              let inputPerM = price.inputPerM,
              let outputPerM = price.outputPerM
        else { return nil }

        // 缓存价缺省时按 Anthropic 惯例从输入价推导：读 0.1x、5m 写 1.25x、1h 写 2x
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
