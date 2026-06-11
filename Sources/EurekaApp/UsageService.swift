import AppKit
import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

/// 用量服务：持有 SQLite + 双扫描器，定时增量扫描并发布汇总。
/// store/扫描器只在内部串行队列上触碰；@Published 属性只在主线程更新。
final class UsageService: ObservableObject {
    @Published private(set) var summary: UsageSummary?
    @Published private(set) var recentHistory: [FinishedTask] = []
    @Published private(set) var lastError: String?
    @Published private(set) var exportMessage: String?

    private let queue = DispatchQueue(label: "com.vinlee.eureka.usage", qos: .utility)
    private var timer: DispatchSourceTimer?

    // 以下成员只在 queue 上访问
    private var store: EurekaStore?
    private var claudeScanner: ClaudeTranscriptScanner?
    private var codexScanner: CodexUsageScanner?
    private var pricing = PricingTable(models: [])

    private static let claudeHealthName = "用量扫描 Claude"
    private static let codexHealthName = "用量扫描 Codex"

    func start() {
        HealthRegistry.shared.register(Self.claudeHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.codexHealthName, expectedInterval: 60)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let store = try EurekaStore(path: EurekaStore.defaultURL())
                self.store = store
                self.claudeScanner = ClaudeTranscriptScanner(
                    projectsRoot: ClaudeTranscriptScanner.defaultProjectsRoot(), store: store)
                self.codexScanner = CodexUsageScanner(
                    sessionsRoot: CodexRolloutTailer.defaultSessionsRoot(), store: store)
                self.pricing = PricingTable.load(
                    bundledURL: Bundle.module.url(forResource: "pricing", withExtension: "json"),
                    overrideURL: SpoolPaths.root().appendingPathComponent("pricing.json"))
                self.scanAndPublish()
            } catch {
                self.publish { $0.lastError = "数据库打开失败: \(error)" }
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.scanAndPublish() }
        timer.resume()
        self.timer = timer
    }

    /// 任务完成 → 写历史（状态机副作用，主线程调用）
    func recordFinished(_ task: FinishedTask) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            try? store.history.insert(task)
            self.publishHistory(store: store)
        }
    }

    /// popover 打开时主动刷一次
    func refreshNow() {
        queue.async { [weak self] in self?.scanAndPublish() }
    }

    /// 导出近 30 天用量 CSV 到 ~/Downloads 并在 Finder 中显示
    func exportCSV() {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            do {
                let now = Date()
                let rows = try store.usage.dailyRows(
                    from: now.addingTimeInterval(-30 * 86400), to: now)
                var csv = "date,source,model,project,input_tokens,output_tokens,"
                    + "cache_write_tokens,cache_read_tokens,requests,est_cost_usd\n"
                for row in rows {
                    let cost = self.pricing.cost(of: row.totals)
                        .map { String(format: "%.4f", $0) } ?? ""
                    let project = row.project.replacingOccurrences(of: ",", with: "_")
                    csv += "\(row.day),\(row.totals.source.rawValue),\(row.totals.model),"
                        + "\(project),\(row.totals.inputTokens),\(row.totals.outputTokens),"
                        + "\(row.totals.cacheCreationTokens),\(row.totals.cacheReadTokens),"
                        + "\(row.totals.requestCount),\(cost)\n"
                }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd"
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "Downloads/eureka-usage-\(formatter.string(from: now)).csv")
                try Data(csv.utf8).write(to: url)
                self.publish { $0.exportMessage = "已导出 \(url.lastPathComponent)" }
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                self.publish { $0.exportMessage = "导出失败: \(error)" }
            }
        }
    }

    // MARK: - queue 内部

    private func scanAndPublish() {
        guard let store else { return }
        do {
            let claudeNew = try claudeScanner?.scanOnce() ?? 0
            HealthRegistry.shared.beat(Self.claudeHealthName)
            if claudeNew > 0 { HealthRegistry.shared.event(Self.claudeHealthName) }
            let codexNew = try codexScanner?.scanOnce() ?? 0
            HealthRegistry.shared.beat(Self.codexHealthName)
            if codexNew > 0 { HealthRegistry.shared.event(Self.codexHealthName) }
            try store.scanState.pruneDedupKeys(
                before: Date().addingTimeInterval(-8 * 86400))
            let summary = try UsageAggregator.summarize(store: store, pricing: pricing)
            publish { $0.summary = summary }
            publishHistory(store: store)
        } catch {
            HealthRegistry.shared.failure(Self.claudeHealthName, note: "\(error)")
            publish { $0.lastError = "扫描失败: \(error)" }
        }
    }

    private func publishHistory(store: EurekaStore) {
        let history = (try? store.history.recent(limit: 50)) ?? []
        publish { $0.recentHistory = history }
    }

    private func publish(_ apply: @escaping (UsageService) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            apply(self)
        }
    }
}
