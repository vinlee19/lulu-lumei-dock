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

    private let queue = DispatchQueue(label: "com.vinlee.eureka.usage", qos: .utility)
    private var timer: DispatchSourceTimer?

    // 以下成员只在 queue 上访问
    private var store: EurekaStore?
    private var claudeScanner: ClaudeTranscriptScanner?
    private var codexScanner: CodexUsageScanner?
    private var pricing = PricingTable(models: [])

    func start() {
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

    // MARK: - queue 内部

    private func scanAndPublish() {
        guard let store else { return }
        do {
            try claudeScanner?.scanOnce()
            try codexScanner?.scanOnce()
            try store.scanState.pruneDedupKeys(
                before: Date().addingTimeInterval(-8 * 86400))
            let summary = try UsageAggregator.summarize(store: store, pricing: pricing)
            publish { $0.summary = summary }
            publishHistory(store: store)
        } catch {
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
