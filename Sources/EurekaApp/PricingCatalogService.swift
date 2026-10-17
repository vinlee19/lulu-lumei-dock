import EurekaIngest
import EurekaKit
import EurekaUsage
import Foundation

extension PricingPaths {
    /// The four locations the app actually uses
    static var app: PricingPaths {
        PricingPaths(
            bundledTable: AppResources.bundle.url(forResource: "pricing", withExtension: "json"),
            bundledSnapshot: AppResources.bundle.url(forResource: "pricing-catalog", withExtension: "json"),
            cache: SpoolPaths.root().appendingPathComponent("pricing-catalog-cache.json"),
            override: SpoolPaths.root().appendingPathComponent("pricing.json"))
    }
}

/// Remote price catalog service: fetches the public price tables from LiteLLM / models.dev once
/// a day (no user data attached). On success it atomically writes the disk cache and hot-swaps
/// PricingCatalogStore; on failure it retries with backoff, meanwhile using the cache / bundled
/// snapshot.
final class PricingCatalogService: ObservableObject {
    /// Singleton: started by AppDelegate, read directly by Settings (avoids passing it down through
    /// layers)
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

    /// Called after the price table is replaced (main thread): usage / session pages recompute
    /// costs
    var onPricingChanged: (() -> Void)?

    private let queue = DispatchQueue(label: "com.vinlee.eureka.pricing", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Everything below is accessed only on queue
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
        // Lightweight per-minute check (timestamps only); the real network fetch happens once a day
        // or per backoff
        timer.schedule(deadline: .now() + 10, repeating: 60, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.tick(force: false) }
        timer.resume()
        self.timer = timer
    }

    /// Settings "Update Now"
    func refreshNow() {
        queue.async { [weak self] in self?.tick(force: true) }
    }

    /// User edited pricing.json: rebuild the price table
    func reloadOverride() {
        queue.async { [weak self] in
            PricingCatalogStore.shared.reloadOverride()
            self?.publishStatus(error: nil)
            DispatchQueue.main.async { self?.onPricingChanged?() }
        }
    }

    // MARK: - queue internals

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

    /// Synchronous HTTP (blocks waiting on the utility queue, same approach as
    /// URLSessionTransport). ephemeral: no cookies / cache; requests carry only User-Agent and
    /// conditional headers.
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
