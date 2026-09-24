import Foundation

/// 价格相关文件的位置（EurekaUsage 不碰 Bundle，由 app 层传入）
public struct PricingPaths: Sendable {
    /// 随包手写表 Resources/pricing.json
    public var bundledTable: URL?
    /// 随包价格目录快照 Resources/pricing-catalog.json（发版前 make pricing-catalog 生成）
    public var bundledSnapshot: URL?
    /// 上次成功拉取的目录缓存（永久保留）
    public var cache: URL?
    /// 用户覆盖文件（最上层）
    public var override: URL?

    public init(bundledTable: URL?, bundledSnapshot: URL?, cache: URL?, override: URL?) {
        self.bundledTable = bundledTable
        self.bundledSnapshot = bundledSnapshot
        self.cache = cache
        self.override = override
    }
}

/// 当前生效的价格目录从哪来（设置页展示）
public enum CatalogOrigin: String, Sendable {
    case none = "无"
    case snapshot = "随包快照"
    case cache = "本地缓存"
    case remote = "远程"
}

/// 全进程共享的价格表容器：加锁持有当前 PricingTable，新目录到达时原子替换。
/// UsageService / SessionBrowserService / 看板都从这里取，保证同一时刻口径一致。
public final class PricingCatalogStore: @unchecked Sendable {
    public static let shared = PricingCatalogStore()

    private let lock = NSLock()
    private var paths: PricingPaths?
    private var table = PricingTable(models: [])
    private var catalog = PriceCatalog.empty
    private var origin = CatalogOrigin.none
    private var revisionValue = 0

    public init() {}

    public var current: PricingTable {
        lock.lock()
        defer { lock.unlock() }
        return table
    }

    public var currentCatalog: PriceCatalog {
        lock.lock()
        defer { lock.unlock() }
        return catalog
    }

    public var currentOrigin: CatalogOrigin {
        lock.lock()
        defer { lock.unlock() }
        return origin
    }

    /// 每次替换 +1，调用方据此判断要不要重算费用
    public var revision: Int {
        lock.lock()
        defer { lock.unlock() }
        return revisionValue
    }

    /// 首次加载：磁盘缓存与随包快照逐来源取较新者（发版更新了快照就胜过旧缓存）。幂等。
    public func loadIfNeeded(paths: PricingPaths) {
        lock.lock()
        let loaded = self.paths != nil
        lock.unlock()
        guard !loaded else { return }
        let snapshot = paths.bundledSnapshot.flatMap(Self.readCatalog) ?? .empty
        let cached = paths.cache.flatMap(Self.readCatalog) ?? .empty
        let merged = PriceCatalog.newest(cached, snapshot)
        let origin: CatalogOrigin
        if merged.isEmpty {
            origin = .none
        } else if !cached.isEmpty, merged.litellmMeta == cached.litellmMeta
            || merged.modelsDevMeta == cached.modelsDevMeta {
            origin = .cache
        } else {
            origin = .snapshot
        }
        replace(paths: paths, catalog: merged, origin: origin)
    }

    /// 新拉到的目录：替换并返回新 revision
    @discardableResult
    public func install(catalog: PriceCatalog, origin: CatalogOrigin = .remote) -> Int {
        lock.lock()
        let paths = self.paths
        lock.unlock()
        guard let paths else { return revision }
        return replace(paths: paths, catalog: catalog, origin: origin)
    }

    /// 用户改了 pricing.json：保持目录不变，重建表
    @discardableResult
    public func reloadOverride() -> Int {
        lock.lock()
        let paths = self.paths
        let catalog = self.catalog
        let origin = self.origin
        lock.unlock()
        guard let paths else { return revision }
        return replace(paths: paths, catalog: catalog, origin: origin)
    }

    @discardableResult
    private func replace(paths: PricingPaths, catalog: PriceCatalog, origin: CatalogOrigin) -> Int {
        let table = PricingTable.load(
            bundledURL: paths.bundledTable, overrideURL: paths.override, catalog: catalog)
        lock.lock()
        defer { lock.unlock() }
        self.paths = paths
        self.table = table
        self.catalog = catalog
        self.origin = origin
        revisionValue += 1
        return revisionValue
    }

    // MARK: - 序列化

    public static func encode(_ catalog: PriceCatalog) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(catalog)
    }

    public static func decode(_ data: Data) throws -> PriceCatalog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(PriceCatalog.self, from: data)
    }

    /// 读缓存/快照：文件缺失或损坏 → nil（落到下一层兜底，不报错）
    static func readCatalog(_ url: URL) -> PriceCatalog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }
}
