import AppKit
import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

/// 安全审计服务：持有独立 SQLite 连接 + AuditPipeline + Codex/CodeBuddy/Qoder 审计扫描器。
/// Claude 与 Trae 的操作经 EventPipeline 旁路送入（ingestHook），其余靠定时扫描 jsonl。
/// store/pipeline/scanner 只在内部串行队列上触碰；@Published 只在主线程更新。
final class AuditService: ObservableObject {
    /// 审计面板当前页（倒序）与总条数
    @Published private(set) var events: [AuditEvent] = []
    @Published private(set) var total = 0
    @Published private(set) var riskTotal = 0
    @Published private(set) var lastError: String?
    @Published private(set) var exportMessage: String?
    /// 按来源 / 类型分组的计数（筛选 chip 与总览卡的分布）。
    /// ⚠️ `SourceFilterBar` 的 `count:` 闭包在渲染里**逐 chip 调用**，只能读这两个字典，
    /// 绝不能每次都查库。
    @Published private(set) var sourceCounts: [AgentSource: Int] = [:]
    @Published private(set) var kindCounts: [ToolKind: Int] = [:]

    /// 命中高危规则时回调（主线程）：AppDelegate 转成岛卡 + 系统通知
    var onRiskAlert: ((RiskAlert) -> Void)?

    private let queue = DispatchQueue(label: "com.vinlee.eureka.audit", qos: .utility)
    private var timer: DispatchSourceTimer?

    // 以下成员只在 queue 上访问
    private var store: EurekaStore?
    private var pipeline: AuditPipeline?
    private var codexScanner: CodexAuditScanner?
    private var codeBuddyScanner: CodeBuddyAuditScanner?
    private var qoderScanner: QoderAuditScanner?
    private var cursorScanner: CursorAuditScanner?
    private var grokScanner: GrokAuditScanner?
    private var qwenScanner: QwenAuditScanner?
    private var captureEnabled = true
    private var retentionDays = 90
    private var lastPruneAt = Date.distantPast

    private static let codexHealthName = "审计扫描 Codex"
    private static let codeBuddyHealthName = "审计扫描 CodeBuddy"
    private static let qoderHealthName = "审计扫描 Qoder"
    private static let cursorHealthName = "审计扫描 Cursor"
    private static let grokHealthName = "审计扫描 Grok"
    private static let qwenHealthName = "审计扫描 Qwen"

    func start() {
        HealthRegistry.shared.register(Self.codexHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.codeBuddyHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.qoderHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.cursorHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.grokHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.qwenHealthName, expectedInterval: 60)
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
                self.codeBuddyScanner = CodeBuddyAuditScanner(
                    projectsRoot: CodeBuddyPaths.projectsRoot(),
                    store: store, pipeline: pipeline)
                self.qoderScanner = QoderAuditScanner(
                    projectsRoot: QoderPaths.projectsRoot(),
                    store: store, pipeline: pipeline)
                self.cursorScanner = CursorAuditScanner(
                    dbPath: CursorPaths.globalStateDB(),
                    workspaceStorageRoot: CursorPaths.workspaceStorageRoot(),
                    store: store, pipeline: pipeline)
                self.grokScanner = GrokAuditScanner(
                    sessionsRoot: GrokPaths.sessionsRoot(),
                    store: store, pipeline: pipeline)
                self.qwenScanner = QwenAuditScanner(
                    projectsRoot: QwenPaths.projectsRoot(),
                    store: store, pipeline: pipeline)
                self.scanCodex()
                self.scanCodeBuddy()
                self.scanQoder()
                self.scanCursor()
                self.scanGrok()
                self.scanQwen()
                self.pruneIfDue()
            } catch {
                self.publish { $0.lastError = "审计库打开失败: \(error)" }
            }
        }
        // 2s 近实时扫描 Codex/CodeBuddy/Qoder/Cursor/Grok/Qwen + 顺带到点清理
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // leeway 让系统合并唤醒省电
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.scanCodex()
            self?.scanCodeBuddy()
            self?.scanQoder()
            self?.scanCursor()
            self?.scanGrok()
            self?.scanQwen()
            self?.pruneIfDue()
        }
        timer.resume()
        self.timer = timer
    }

    /// Claude PostToolUse 旁路事件（EventPipeline 队列回调 → 切到审计队列串行处理）
    /// hook 通道（Claude / Trae）的 PostToolUse 旁路入口。事件自带 source，此处不区分。
    func ingestHook(_ event: AuditEvent, isStale: Bool) {
        queue.async { [weak self] in
            guard let self, self.captureEnabled, let pipeline = self.pipeline else { return }
            do {
                let result = try pipeline.ingest(event, isStale: isStale)
                if let alert = result.alert { self.emit(alert) }
            } catch {
                self.publish { $0.lastError = "\(event.source.displayName) 审计写入失败: \(error)" }
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
                // 分布计数各自去掉自己那一维：否则选中某来源后其余 chip 全变 0，
                // 用户就看不出「切过去还有多少条」。
                var sourceQuery = query
                sourceQuery.source = nil
                var kindQuery = query
                kindQuery.kind = nil
                let bySource = try store.audit.counts(by: .source, sourceQuery)
                let byKind = try store.audit.counts(by: .kind, kindQuery)
                self.publish {
                    $0.events = rows
                    $0.total = total
                    $0.riskTotal = riskTotal
                    $0.lastError = nil
                    $0.sourceCounts = Dictionary(
                        uniqueKeysWithValues: bySource.compactMap { key, value in
                            AgentSource(rawValue: key).map { ($0, value) }
                        })
                    $0.kindCounts = Dictionary(
                        uniqueKeysWithValues: byKind.compactMap { key, value in
                            ToolKind(rawValue: key).map { ($0, value) }
                        })
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
        HealthRegistry.shared.beat(Self.codexHealthName)
        do {
            let new = try scanner.scanOnce { [weak self] alert in self?.emit(alert) }
            if new > 0 { HealthRegistry.shared.event(Self.codexHealthName) }
        } catch {
            HealthRegistry.shared.failure(Self.codexHealthName, note: "\(error)")
        }
    }

    private func scanCodeBuddy() {
        guard captureEnabled, let scanner = codeBuddyScanner else { return }
        HealthRegistry.shared.beat(Self.codeBuddyHealthName)
        do {
            let new = try scanner.scanOnce { [weak self] alert in self?.emit(alert) }
            if new > 0 { HealthRegistry.shared.event(Self.codeBuddyHealthName) }
        } catch {
            HealthRegistry.shared.failure(Self.codeBuddyHealthName, note: "\(error)")
        }
    }

    private func scanQoder() {
        guard captureEnabled, let scanner = qoderScanner else { return }
        HealthRegistry.shared.beat(Self.qoderHealthName)
        do {
            let new = try scanner.scanOnce { [weak self] alert in self?.emit(alert) }
            if new > 0 { HealthRegistry.shared.event(Self.qoderHealthName) }
        } catch {
            HealthRegistry.shared.failure(Self.qoderHealthName, note: "\(error)")
        }
    }

    private func scanCursor() {
        guard captureEnabled, let scanner = cursorScanner else { return }
        HealthRegistry.shared.beat(Self.cursorHealthName)
        do {
            let new = try scanner.scanOnce { [weak self] alert in self?.emit(alert) }
            if new > 0 { HealthRegistry.shared.event(Self.cursorHealthName) }
        } catch {
            HealthRegistry.shared.failure(Self.cursorHealthName, note: "\(error)")
        }
    }

    private func scanGrok() {
        guard captureEnabled, let scanner = grokScanner else { return }
        HealthRegistry.shared.beat(Self.grokHealthName)
        do {
            let new = try scanner.scanOnce { [weak self] alert in self?.emit(alert) }
            if new > 0 { HealthRegistry.shared.event(Self.grokHealthName) }
        } catch {
            HealthRegistry.shared.failure(Self.grokHealthName, note: "\(error)")
        }
    }

    private func scanQwen() {
        guard captureEnabled, let scanner = qwenScanner else { return }
        HealthRegistry.shared.beat(Self.qwenHealthName)
        do {
            let new = try scanner.scanOnce { [weak self] alert in self?.emit(alert) }
            if new > 0 { HealthRegistry.shared.event(Self.qwenHealthName) }
        } catch {
            HealthRegistry.shared.failure(Self.qwenHealthName, note: "\(error)")
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
