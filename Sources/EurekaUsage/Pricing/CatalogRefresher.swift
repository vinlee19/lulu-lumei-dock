import Foundation

/// 一次 HTTP 请求的结果（传输层由 app 注入，测试用假实现）
public struct CatalogFetchResponse: Sendable {
    public var status: Int
    public var body: Data
    /// 响应头（键已小写）
    public var headers: [String: String]

    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    }
}

public typealias CatalogFetch = (URLRequest) throws -> CatalogFetchResponse

/// 远程价格目录的拉取与合并策略（纯编排，无定时器 / 无文件 IO）。
/// 每个来源按镜像顺序尝试；任何失败都保留上一份数据，绝不因为网络问题把价格清空。
public enum CatalogRefresher {
    public static let litellmURLs = [
        URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!,
        // raw.githubusercontent 在国内经常不通，jsDelivr 镜像兜底
        URL(string: "https://cdn.jsdelivr.net/gh/BerriAI/litellm@main/model_prices_and_context_window.json")!,
    ]
    public static let modelsDevURLs = [
        URL(string: "https://models.dev/api.json")!,
    ]

    /// 正常刷新周期
    public static let refreshInterval: TimeInterval = 24 * 3600
    /// 连续失败的退避序列（最后一档封顶）
    public static let backoff: [TimeInterval] = [60, 300, 1800, 7200, 21600]

    public static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return refreshInterval }
        return backoff[min(failures - 1, backoff.count - 1)]
    }

    /// 是否该拉取：从未成功过，或距上次成功已满一个周期
    public static func isDue(lastSuccess: Date?, now: Date) -> Bool {
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= refreshInterval
    }

    public struct Outcome: Sendable {
        public var catalog: PriceCatalog
        /// 有来源拿到了新内容（200）；304 或全失败为 false
        public var changed: Bool
        /// 两个来源都至少有一个镜像成功（200 或 304）
        public var succeeded: Bool
        public var errors: [String]
    }

    /// minimums：有效条目下限（测试用小样本时调低，线上用默认值）
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
        return .failed("\(name) 更新失败：" + failures.joined(separator: "；"))
    }
}
