import EurekaKit
import Foundation

/// Result of one HTTP request (the transport is injected by the app; tests use a fake)
public struct CatalogFetchResponse: Sendable {
    public var status: Int
    public var body: Data
    /// Response headers (keys lowercased)
    public var headers: [String: String]

    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    }
}

public typealias CatalogFetch = (URLRequest) throws -> CatalogFetchResponse

/// Fetch-and-merge policy for the remote price catalogs (pure orchestration: no timers, no file
/// IO). Each source tries its mirrors in order; any failure keeps the previous data - a network
/// problem never blanks prices.
public enum CatalogRefresher {
    public static let litellmURLs = [
        URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!,
        // raw.githubusercontent is often unreachable from mainland China; the jsDelivr mirror is
        // the fallback
        URL(string: "https://cdn.jsdelivr.net/gh/BerriAI/litellm@main/model_prices_and_context_window.json")!,
    ]
    public static let modelsDevURLs = [
        URL(string: "https://models.dev/api.json")!,
    ]

    /// Normal refresh interval
    public static let refreshInterval: TimeInterval = 24 * 3600
    /// Backoff sequence for consecutive failures (the last step is the cap)
    public static let backoff: [TimeInterval] = [60, 300, 1800, 7200, 21600]

    public static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return refreshInterval }
        return backoff[min(failures - 1, backoff.count - 1)]
    }

    /// Whether to fetch: never succeeded, or a full interval has passed since the last success
    public static func isDue(lastSuccess: Date?, now: Date) -> Bool {
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= refreshInterval
    }

    public struct Outcome: Sendable {
        public var catalog: PriceCatalog
        /// Some source got new content (200); false on 304 or total failure
        public var changed: Bool
        /// Both sources had at least one mirror succeed (200 or 304)
        public var succeeded: Bool
        public var errors: [String]
    }

    /// minimums: lower bound on valid entries (lowered for small test samples; production uses the
    /// defaults)
    public static func refresh(
        previous: PriceCatalog, now: Date = Date(),
        minimums: (litellm: Int, modelsDev: Int) = (
            PriceCatalogParser.litellmMinEntries, PriceCatalogParser.modelsDevMinProviders),
        fetch: CatalogFetch
    ) -> Outcome {
        var catalog = previous
        var changed = false
        var errors: [String] = []

        let litellm = refreshSource(
            name: "LiteLLM", urls: litellmURLs, meta: previous.litellmMeta, now: now, fetch: fetch
        ) { data in
            let parsed = try PriceCatalogParser.parseLiteLLM(data, minEntries: minimums.litellm)
            try PriceCatalogParser.checkNotCollapsed(
                new: parsed.count, previous: previous.litellm.isEmpty ? nil : previous.litellm.count,
                name: "LiteLLM")
            return (parsed.count, { catalog.litellm = parsed })
        }
        switch litellm {
        case .updated(let meta, let apply): apply(); catalog.litellmMeta = meta; changed = true
        case .notModified(let meta): catalog.litellmMeta = meta
        case .failed(let message): errors.append(message)
        }

        let modelsDev = refreshSource(
            name: "models.dev", urls: modelsDevURLs, meta: previous.modelsDevMeta, now: now, fetch: fetch
        ) { data in
            let parsed = try PriceCatalogParser.parseModelsDev(data, minProviders: minimums.modelsDev)
            try PriceCatalogParser.checkNotCollapsed(
                new: parsed.count, previous: previous.modelsDev.isEmpty ? nil : previous.modelsDev.count,
                name: "models.dev")
            return (parsed.values.reduce(0) { $0 + $1.models.count }, { catalog.modelsDev = parsed })
        }
        switch modelsDev {
        case .updated(let meta, let apply): apply(); catalog.modelsDevMeta = meta; changed = true
        case .notModified(let meta): catalog.modelsDevMeta = meta
        case .failed(let message): errors.append(message)
        }

        return Outcome(catalog: catalog, changed: changed, succeeded: errors.isEmpty, errors: errors)
    }

    private enum SourceResult {
        case updated(PriceCatalog.SourceMeta, () -> Void)
        case notModified(PriceCatalog.SourceMeta)
        case failed(String)
    }

    private static func refreshSource(
        name: String, urls: [URL], meta: PriceCatalog.SourceMeta?, now: Date, fetch: CatalogFetch,
        parse: (Data) throws -> (count: Int, apply: () -> Void)
    ) -> SourceResult {
        var failures: [String] = []
        for url in urls {
            var request = URLRequest(url: url)
            request.setValue("Eureka-pricing", forHTTPHeaderField: "User-Agent")
            if let etag = meta?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = meta?.lastModified {
                request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
            }
            do {
                let response = try fetch(request)
                if response.status == 304, var kept = meta {
                    kept.fetchedAt = now
                    return .notModified(kept)
                }
                guard response.status == 200 else {
                    failures.append("\(url.host ?? "?") HTTP \(response.status)")
                    continue
                }
                let (count, apply) = try parse(response.body)
                let newMeta = PriceCatalog.SourceMeta(
                    fetchedAt: now, etag: response.headers["etag"],
                    lastModified: response.headers["last-modified"], entryCount: count)
                return .updated(newMeta, apply)
            } catch {
                failures.append("\(url.host ?? "?") \(error)")
            }
        }
        return .failed(L10n.format("%@ update failed: ", zhHans: "%@ 更新失败：", String(name)) + failures.joined(separator: L10n.text("; ", zhHans: "；")))
    }
}
