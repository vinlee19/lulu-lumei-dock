import EurekaIngest
import EurekaKit
import EurekaUsage
import Foundation

extension PricingPaths {
    /// app 实际使用的四个位置
    static var app: PricingPaths {
        PricingPaths(
            bundledTable: AppResources.bundle.url(forResource: "pricing", withExtension: "json"),
            bundledSnapshot: AppResources.bundle.url(forResource: "pricing-catalog", withExtension: "json"),
            cache: SpoolPaths.root().appendingPathComponent("pricing-catalog-cache.json"),
            override: SpoolPaths.root().appendingPathComponent("pricing.json"))
    }
}

/// 远程价格目录服务：每天从 LiteLLM / models.dev 拉一次公开价格表（不带任何用户数据），
/// 成功后原子写磁盘缓存并热替换 PricingCatalogStore；失败按退避重试，期间继续用缓存/随包快照。
final class PricingCatalogService: ObservableObject {
    /// 单例：AppDelegate 启动，设置页直接取用（免得层层传参）
    static let shared = PricingCatalogService()
    struct Status: Equatable {
        var origin: CatalogOrigin = .none
        var litellmFetchedAt: Date?
        var modelsDevFetchedAt: Date?
        var litellmCount = 0
        var modelsDevCount = 0
        var lastError: String?
        var refreshing = false
    }

    static let healthName = "价格目录"
    static let enabledKey = "remotePricingEnabled"

    @Published private(set) var status = Status()

    /// 价格表替换后回调（主线程）：用量/会话页据此重算费用
    var onPricingChanged: (() -> Void)?

    private let queue = DispatchQueue(label: "com.vinlee.eureka.pricing", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// 以下仅 queue 上访问
    private var failures = 0
    private var nextAttemptAt = Date.distantPast
    private var running = false

    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    func start() {
        HealthRegistry.shared.register(Self.healthName, expectedInterval: CatalogRefresher.refreshInterval)
        queue.async { [weak self] in
            PricingCatalogStore.shared.loadIfNeeded(paths: .app)
            self?.publishStatus(error: nil)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // 分钟级轻量检查（只比时间戳），真正联网一天一次或按退避
        timer.schedule(deadline: .now() + 10, repeating: 60, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.tick(force: false) }
        timer.resume()
        self.timer = timer
    }

    /// 设置页「立即更新」
    func refreshNow() {
        queue.async { [weak self] in self?.tick(force: true) }
    }

    /// 用户改了 pricing.json：重建价格表
    func reloadOverride() {
        queue.async { [weak self] in
            PricingCatalogStore.shared.reloadOverride()
            self?.publishStatus(error: nil)
            DispatchQueue.main.async { self?.onPricingChanged?() }
        }
    }

    // MARK: - queue 内部

    private func tick(force: Bool) {
        guard !running else { return }
        guard force || Self.isEnabled else { return }
        let now = Date()
        let catalog = PricingCatalogStore.shared.currentCatalog
        let lastSuccess = [catalog.litellmMeta?.fetchedAt, catalog.modelsDevMeta?.fetchedAt]
            .compactMap { $0 }.min()
        if !force {
            guard now >= nextAttemptAt,
                  failures > 0 || CatalogRefresher.isDue(lastSuccess: lastSuccess, now: now)
            else { return }
        }
        running = true
        DispatchQueue.main.async { self.status.refreshing = true }

        let outcome = CatalogRefresher.refresh(previous: catalog, now: now, fetch: Self.fetch)
        if outcome.changed || outcome.succeeded {
            if let data = try? PricingCatalogStore.encode(outcome.catalog),
               let cacheURL = PricingPaths.app.cache {
                try? FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
            PricingCatalogStore.shared.install(catalog: outcome.catalog, origin: .remote)
            if outcome.changed {
                DispatchQueue.main.async { [weak self] in self?.onPricingChanged?() }
            }
        }
        if outcome.succeeded {
            failures = 0
            nextAttemptAt = now.addingTimeInterval(CatalogRefresher.refreshInterval)
            HealthRegistry.shared.beat(Self.healthName)
        } else {
            failures += 1
            nextAttemptAt = now.addingTimeInterval(CatalogRefresher.retryDelay(afterFailures: failures))
            HealthRegistry.shared.failure(Self.healthName, note: outcome.errors.joined(separator: "；"))
        }
        running = false
        publishStatus(error: outcome.errors.isEmpty ? nil : outcome.errors.joined(separator: "；"))
    }

    private func publishStatus(error: String?) {
        let store = PricingCatalogStore.shared
        let catalog = store.currentCatalog
        let next = Status(
            origin: store.currentOrigin,
            litellmFetchedAt: catalog.litellmMeta?.fetchedAt,
            modelsDevFetchedAt: catalog.modelsDevMeta?.fetchedAt,
            litellmCount: catalog.litellm.count,
            modelsDevCount: catalog.modelsDev.values.reduce(0) { $0 + $1.models.count },
            lastError: error,
            refreshing: false)
        DispatchQueue.main.async { [weak self] in self?.status = next }
    }

    /// 同步 HTTP（在 utility 队列上阻塞等待，与 URLSessionTransport 同法）。
    /// ephemeral：不存 cookie / 缓存，请求只带 User-Agent 与条件头。
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 90
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func fetch(_ request: URLRequest) throws -> CatalogFetchResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<CatalogFetchResponse, Error> = .failure(URLError(.unknown))
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    if let key = key as? String, let value = value as? String { headers[key] = value }
                }
                result = .success(CatalogFetchResponse(
                    status: http.statusCode, body: data ?? Data(), headers: headers))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return try result.get()
    }
}
