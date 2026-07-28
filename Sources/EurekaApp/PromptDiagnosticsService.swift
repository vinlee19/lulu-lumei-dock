import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

/// 跨会话提示词诊断：读 `turn_metrics`（由 `TurnMetricsIndexer` 在用量的 60s 节奏里增量落库）。
///
/// 自己开独立 SQLite 连接 + 串行队列（同 `AuditService` 的做法）：
/// 页面查询不能挤在用量扫描那条队列上，否则一次全量扫描会把页面卡住。
/// ⚠️ **不要标 `@MainActor`**：那样每个方法都成主线程隔离，队列闭包里读属性只能靠
/// `MainActor.assumeIsolated`，而它在后台线程上会陷阱/阻塞，表现就是「重扫毫无反应」。
/// 照 `AuditService` 的做法：普通类 + 队列内私有状态 + `publish` 回主线程。
final class PromptDiagnosticsService: ObservableObject {
    @Published private(set) var aggregate = TurnMetricsAggregate()
    @Published private(set) var series: [(day: Date, total: Int, bad: Int)] = []
    @Published private(set) var worst: [TurnMetricRow] = []
    @Published private(set) var totalRows = 0
    @Published private(set) var loading = false
    @Published private(set) var lastError: String?
    @Published var sourceFilter: AgentSource? { didSet { syncQuery(); load() } }
    /// 统计窗口天数
    @Published var windowDays = 30 { didSet { syncQuery(); load() } }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.diagnostics", qos: .utility)
    // 以下成员只在 queue 上访问（主线程改动通过 syncQuery 推过去，不反向读）
    private var store: EurekaStore?
    private var queryDays = 30
    private var querySource: String?

    /// 主线程的筛选条件 → 队列私有副本（避免队列上读 @Published 造成数据竞争）
    private func syncQuery() {
        let days = windowDays
        let source = sourceFilter?.rawValue
        queue.async { [weak self] in
            self?.queryDays = days
            self?.querySource = source
        }
    }

    func load() {
        loading = true
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let store = try self.openStore()
                let now = Date()
                let from = now.addingTimeInterval(-Double(self.queryDays) * 86400)
                let source = self.querySource
                let aggregate = try store.turnMetrics.aggregate(
                    from: from, to: now.addingTimeInterval(86400), source: source)
                let series = try store.turnMetrics.dailySeries(
                    from: from, to: now.addingTimeInterval(86400), source: source)
                let worst = try store.turnMetrics.worst(limit: 20, source: source)
                let total = try store.turnMetrics.count()
                self.publish {
                    $0.aggregate = aggregate
                    $0.series = series
                    $0.worst = worst
                    $0.totalRows = total
                    $0.lastError = nil
                    $0.loading = false
                }
            } catch {
                self.publish {
                    $0.lastError = "读取诊断数据失败: \(error)"
                    $0.loading = false
                }
            }
        }
    }

    /// 强制重扫一遍（首次进页面时索引可能还没跑过）
    func rescan() {
        loading = true
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let store = try self.openStore()
                let rebuilt = try TurnMetricsIndexer(store: store).indexOnce()
                print("[diagnostics] 重扫完成，重建 \(rebuilt) 个文件")
            } catch {
                self.publish { $0.lastError = "重扫失败: \(error)" }
            }
            DispatchQueue.main.async { self.load() }
        }
    }

    // MARK: - 内部

    private func openStore() throws -> EurekaStore {
        if let store { return store }
        let store = try EurekaStore(path: EurekaStore.defaultURL())
        self.store = store
        return store
    }

    private func publish(_ apply: @escaping (PromptDiagnosticsService) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            apply(self)
        }
    }
}
