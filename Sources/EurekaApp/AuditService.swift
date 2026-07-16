import AppKit
import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

/// 安全审计服务：持有独立 SQLite 连接 + AuditPipeline + Codex 审计扫描器。
/// Claude 操作经 EventPipeline 旁路送入（ingestClaude），Codex 靠定时扫描 rollout。
/// store/pipeline/scanner 只在内部串行队列上触碰；@Published 只在主线程更新。
final class AuditService: ObservableObject {
    /// 审计面板当前页（倒序）与总条数
    @Published private(set) var events: [AuditEvent] = []
    @Published private(set) var total = 0
    @Published private(set) var riskTotal = 0
    @Published private(set) var lastError: String?
    @Published private(set) var exportMessage: String?

    /// 命中高危规则时回调（主线程）：AppDelegate 转成岛卡 + 系统通知
    var onRiskAlert: ((RiskAlert) -> Void)?

    private let queue = DispatchQueue(label: "com.vinlee.eureka.audit", qos: .utility)
    private var timer: DispatchSourceTimer?

    // 以下成员只在 queue 上访问
    private var store: EurekaStore?
    private var pipeline: AuditPipeline?
    private var codexScanner: CodexAuditScanner?
    private var captureEnabled = true
    private var retentionDays = 90
    private var lastPruneAt = Date.distantPast

    private static let healthName = "审计扫描 Codex"

    func start() {
        HealthRegistry.shared.register(Self.healthName, expectedInterval: 60)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let store = try EurekaStore(path: EurekaStore.defaultURL())
                let pipeline = AuditPipeline(store: store)
                self.store = store
                self.pipeline = pipeline
                self.codexScanner = CodexAuditScanner(
                    sessionsRoot: CodexRolloutTailer.defaultSessionsRoot(),
                    store: store, pipeline: pipeline)
                self.scanCodex()
                self.pruneIfDue()
            } catch {
                self.publish { $0.lastError = "审计库打开失败: \(error)" }
            }
        }
        // 2s 近实时扫描 Codex + 顺带到点清理
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.scanCodex()
            self?.pruneIfDue()
        }
        timer.resume()
        self.timer = timer
    }

    /// Claude PostToolUse 旁路事件（EventPipeline 队列回调 → 切到审计队列串行处理）
    func ingestClaude(_ event: AuditEvent, isStale: Bool) {
        queue.async { [weak self] in
            guard let self, self.captureEnabled, let pipeline = self.pipeline else { return }
            do {
                let result = try pipeline.ingest(event, isStale: isStale)
                if let alert = result.alert { self.emit(alert) }
            } catch {
                self.publish { $0.lastError = "Claude 审计写入失败: \(error)" }
            }
        }
    }

    // MARK: - 设置绑定（主线程调用，切队列生效）

    func setCaptureEnabled(_ enabled: Bool) {
        queue.async { [weak self] in self?.captureEnabled = enabled }
    }

    func updateRetention(days: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.retentionDays = days
            self.lastPruneAt = .distantPast  // 立即按新策略清一次
            self.pruneIfDue()
        }
    }

    // MARK: - 面板数据

    /// 分页加载（page 从 1 起）
    func load(query: AuditRepo.Query, page: Int, pageSize: Int = 100) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            do {
                let total = try store.audit.count(query)
                let rows = try store.audit.recent(
                    query, limit: pageSize, offset: (max(1, page) - 1) * pageSize)
                let riskTotal = try store.audit.count(.init(riskOnly: true))
                self.publish {
                    $0.events = rows
                    $0.total = total
                    $0.riskTotal = riskTotal
                }
            } catch {
                self.publish { $0.lastError = "读取审计流水失败: \(error)" }
            }
        }
    }

    /// 导出当前筛选结果为 CSV 到 ~/Downloads 并在 Finder 显示（含敏感命令，调用方须提示）
    func exportCSV(query: AuditRepo.Query) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            do {
                let rows = try store.audit.recent(query, limit: 100_000)
                let isoFormatter = ISO8601DateFormatter()
                var csv = "timestamp,source,session,kind,tool,detail,exit_code,is_error,risk_level,risk_rule\n"
                for row in rows {
                    csv += [
                        isoFormatter.string(from: row.timestamp),
                        row.source.rawValue, row.sessionId, row.kind.rawValue,
                        Self.csvField(row.tool), Self.csvField(row.detail),
                        row.exitCode.map(String.init) ?? "",
                        row.isError ? "1" : "0",
                        row.riskLevel?.label ?? "", row.riskRule ?? "",
                    ].joined(separator: ",") + "\n"
                }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads/eureka-audit-\(formatter.string(from: Date())).csv")
                try Data(csv.utf8).write(to: url)
                self.publish { $0.exportMessage = "已导出 \(url.lastPathComponent)（\(rows.count) 条）" }
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                self.publish { $0.exportMessage = "导出失败: \(error)" }
            }
        }
    }

    /// 清空全部审计数据
    func clearAll() {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            try? store.audit.deleteAll()
            self.publish {
                $0.events = []
                $0.total = 0
                $0.riskTotal = 0
                $0.exportMessage = "审计数据已清空"
            }
        }
    }

    // MARK: - queue 内部

    private func scanCodex() {
        guard captureEnabled, let scanner = codexScanner else { return }
        HealthRegistry.shared.beat(Self.healthName)
        do {
            let new = try scanner.scanOnce { [weak self] alert in self?.emit(alert) }
            if new > 0 { HealthRegistry.shared.event(Self.healthName) }
        } catch {
            HealthRegistry.shared.failure(Self.healthName, note: "\(error)")
        }
    }

    /// 每小时清理一次：按天数窗口 + 兜底 20 万行上限
    private func pruneIfDue() {
        guard let store, Date().timeIntervalSince(lastPruneAt) > 3600 else { return }
        lastPruneAt = Date()
        if retentionDays > 0 {
            try? store.audit.prune(
                olderThan: Date().addingTimeInterval(-Double(retentionDays) * 86400))
        }
        try? store.audit.prune(keepingLast: 200_000)
    }

    private func emit(_ alert: RiskAlert) {
        DispatchQueue.main.async { [weak self] in self?.onRiskAlert?(alert) }
    }

    private func publish(_ apply: @escaping (AuditService) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            apply(self)
        }
    }

    private static func csvField(_ value: String) -> String {
        // 含逗号/引号/换行时用引号包裹并转义内部引号
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
