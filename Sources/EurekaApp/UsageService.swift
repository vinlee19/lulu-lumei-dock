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
    /// 请求日志当前页（倒序）与总条数（仪表盘分页用）
    @Published private(set) var records: [RecordDisplay] = []
    @Published private(set) var recordTotal = 0
    /// 模型统计（选中时段/来源的完整分项）
    @Published private(set) var modelTotals: [UsageTotals] = []
    /// 选中区间按 (时间桶, 来源) 的 token/成本趋势（图表用；短区间自动切小时粒度）
    @Published private(set) var trend: [TrendPoint] = []
    @Published private(set) var trendIsHourly = false
    /// 工具/技能/插件/子代理调用统计（选中时段/来源）
    @Published private(set) var toolCallTotals: [ToolCallsRepo.ToolCallTotal] = []
    /// 技能全时累计统计（Skills 分析视图：累计次数 / 最近活跃 / 触发时 token）
    @Published private(set) var skillStats: [ToolCallsRepo.SkillUsageStat] = []
    /// 项目统计（选中区间）
    @Published private(set) var projectTotals: [ProjectTotal] = []
    /// 按会话用量排行（选中区间/来源，token 降序 Top 50）
    @Published private(set) var sessionTotals: [SessionTotal] = []
    /// 活跃时段热力格（选中区间/来源，周 × 24h）
    @Published private(set) var heatmapCells: [UsageRepo.HeatmapCell] = []

    struct ProjectTotal: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var tokens: Int
        var costUSD: Double?
    }

    /// 趋势图数据点（一桶一来源；bucket = 日零点或小时整点）
    struct TrendPoint: Identifiable {
        var id: String { "\(bucket.timeIntervalSince1970)-\(source.rawValue)" }
        var bucket: Date
        var source: AgentSource
        var tokens: Int
        var costUSD: Double
    }

    /// 按会话用量排行行（会话名由视图层用 SessionBrowserService.sessionsById join）
    struct SessionTotal: Identifiable, Equatable {
        var id: String { sessionId }
        var sessionId: String
        var source: AgentSource
        var project: String?
        var lastActiveAt: Date
        var tokens: Int
        var requests: Int
        var costUSD: Double?
    }

    /// 仪表盘时间段（口径与 UsageAggregator 一致：日=当天零点、周=周一、月=月初）
    enum DashboardPeriod: String, CaseIterable {
        case today = "今日"
        case week = "本周"
        case month = "本月"
        case custom = "自定义"

        /// 固定档起点（custom 由视图用自选日期决定，此处返回今日零点兜底）
        var startDate: Date {
            var calendar = Calendar.current
            let now = Date()
            switch self {
            case .today, .custom:
                return calendar.startOfDay(for: now)
            case .week:
                calendar.firstWeekday = 2
                let components = calendar.dateComponents(
                    [.yearForWeekOfYear, .weekOfYear], from: now)
                return calendar.date(from: components) ?? calendar.startOfDay(for: now)
            case .month:
                let components = calendar.dateComponents([.year, .month], from: now)
                return calendar.date(from: components) ?? calendar.startOfDay(for: now)
            }
        }
    }

    /// 请求日志展示行（成本已按价格表折算）
    struct RecordDisplay: Identifiable {
        let id = UUID()
        var row: UsageRepo.UsageRecordRow
        var costUSD: Double?
    }

    /// 技能按天调用点（详情页趋势图）
    struct SkillDayCount: Identifiable {
        var id: Double { day.timeIntervalSince1970 }
        var day: Date
        var count: Int
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.usage", qos: .utility)
    private var timer: DispatchSourceTimer?

    // 以下成员只在 queue 上访问
    private var store: EurekaStore?
    private var claudeScanner: ClaudeTranscriptScanner?
    private var codexScanner: CodexUsageScanner?
    private var opencodeScanner: OpencodeUsageScanner?
    private var grokScanner: GrokUsageScanner?
    private var kimiScanner: KimiUsageScanner?
    private var searchIndexer: TranscriptSearchIndexer?
    private var pricing = PricingTable(models: [])

    private static let claudeHealthName = "用量扫描 Claude"
    private static let codexHealthName = "用量扫描 Codex"
    private static let opencodeHealthName = "用量扫描 opencode"
    private static let grokHealthName = "用量扫描 Grok"
    private static let kimiHealthName = "用量扫描 Kimi"

    func start() {
        HealthRegistry.shared.register(Self.claudeHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.codexHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.opencodeHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.grokHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.kimiHealthName, expectedInterval: 60)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let store = try EurekaStore(path: EurekaStore.defaultURL())
                self.store = store
                self.claudeScanner = ClaudeTranscriptScanner(
                    projectsRoot: ClaudeTranscriptScanner.defaultProjectsRoot(), store: store)
                self.codexScanner = CodexUsageScanner(
                    sessionsRoot: CodexRolloutTailer.defaultSessionsRoot(), store: store)
                self.opencodeScanner = OpencodeUsageScanner(
                    dbPath: OpencodePaths.db(), store: store)
                self.grokScanner = GrokUsageScanner(
                    sessionsRoot: GrokPaths.sessionsRoot(), store: store)
                self.kimiScanner = KimiUsageScanner(
                    sessionsRoot: KimiPaths.sessionsRoot(), store: store)
                self.searchIndexer = TranscriptSearchIndexer(store: store)
                self.pricing = PricingTable.load(
                    bundledURL: AppResources.bundle.url(forResource: "pricing", withExtension: "json"),
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

    /// 清空全文索引（设置页「清空全文索引」；下轮扫描按开关状态自动重建）
    func clearSearchIndex() {
        queue.async { [weak self] in
            try? self?.store?.search.clearAll()
        }
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

    /// 请求日志分页加载（page 从 1 起）；行成本用价格表折算
    func loadRecords(
        page: Int, pageSize: Int = 50, source: AgentSource?, from: Date, to: Date
    ) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            do {
                let total = try store.usage.recordCount(from: from, to: to, source: source)
                let rows = try store.usage.recentRecords(
                    from: from, to: to, source: source,
                    limit: pageSize, offset: (max(1, page) - 1) * pageSize)
                let displays = rows.map { row in
                    RecordDisplay(row: row, costUSD: self.pricing.cost(of: UsageTotals(
                        source: row.source, model: row.model,
                        inputTokens: row.inputTokens, outputTokens: row.outputTokens,
                        cacheCreationTokens: row.cacheCreationTokens,
                        cacheCreation1hTokens: row.cacheCreation1hTokens,
                        cacheReadTokens: row.cacheReadTokens, requestCount: 1)))
                }
                self.publish {
                    $0.records = displays
                    $0.recordTotal = total
                }
            } catch {
                self.publish { $0.lastError = "读取请求日志失败: \(error)" }
            }
        }
    }

    /// 选中区间按 (时间桶, 来源) 聚合 token/成本趋势（图表「按日期」，跟随区间联动）。
    /// 区间 ≤48h（今日/短自定义）自动切小时粒度；成本必须在 model 粒度过价目表后再折叠。
    func loadTrend(from: Date, to: Date) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let hourly = to.timeIntervalSince(from) <= 2 * 86400
            let granularity: UsageRepo.TrendGranularity = hourly ? .hour : .day
            let rows = (try? store.usage.dailyRows(
                from: from, to: to, granularity: granularity)) ?? []
            let formatter = DateFormatter()
            formatter.dateFormat = hourly ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            // (桶字符串, 来源) → token/成本求和（行是 model 粒度，成本先按行算再累加）
            var buckets: [String: [AgentSource: (tokens: Int, cost: Double)]] = [:]
            for row in rows {
                let t = row.totals
                let total = t.inputTokens + t.outputTokens
                    + t.cacheCreationTokens + t.cacheReadTokens
                var entry = buckets[row.day, default: [:]][t.source] ?? (tokens: 0, cost: 0)
                entry.tokens += total
                entry.cost += self.pricing.cost(of: t) ?? 0
                buckets[row.day, default: [:]][t.source] = entry
            }
            var points: [TrendPoint] = []
            for (bucketString, bySource) in buckets {
                guard let bucket = formatter.date(from: bucketString) else { continue }
                for (source, entry) in bySource where entry.tokens > 0 {
                    points.append(TrendPoint(
                        bucket: bucket, source: source,
                        tokens: entry.tokens, costUSD: entry.cost))
                }
            }
            points.sort { $0.bucket < $1.bucket }
            self.publish {
                $0.trend = points
                $0.trendIsHourly = hourly
            }
        }
    }

    /// 按会话用量排行（选中区间/来源；按 sessionId 折叠、成本逐 model 行算、token 降序 Top 50）
    func loadSessionTotals(from: Date, to: Date, source: AgentSource?) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let rows = (try? store.usage.totalsBySession(
                from: from, to: to, source: source)) ?? []
            var bySession: [String: SessionTotal] = [:]
            for row in rows {
                let t = row.totals
                let tokens = t.inputTokens + t.outputTokens
                    + t.cacheCreationTokens + t.cacheReadTokens
                let cost = self.pricing.cost(of: t)
                var entry = bySession[row.sessionId] ?? SessionTotal(
                    sessionId: row.sessionId, source: t.source, project: row.project,
                    lastActiveAt: row.lastTs, tokens: 0, requests: 0, costUSD: nil)
                entry.tokens += tokens
                entry.requests += t.requestCount
                entry.lastActiveAt = max(entry.lastActiveAt, row.lastTs)
                if let cost { entry.costUSD = (entry.costUSD ?? 0) + cost }
                if entry.project == nil { entry.project = row.project }
                bySession[row.sessionId] = entry
            }
            let result = Array(
                bySession.values.sorted { $0.tokens > $1.tokens }.prefix(50))
            self.publish { $0.sessionTotals = result }
        }
    }

    /// 活跃时段热力图（选中区间/来源，周 × 24h 一次 SQL 聚合）
    func loadHeatmap(from: Date, to: Date, source: AgentSource?) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let cells = (try? store.usage.hourlyHeatmap(
                from: from, to: to, source: source)) ?? []
            self.publish { $0.heatmapCells = cells }
        }
    }

    /// 工具/技能/插件调用统计（选中区间/来源，count 降序）
    func loadToolCalls(source: AgentSource?, from: Date, to: Date) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let totals = (try? store.toolCalls.totals(
                from: from, to: to, source: source)) ?? []
            self.publish { $0.toolCallTotals = totals }
        }
    }

    /// 技能全时累计统计（Skills 分析视图；kind='skill'，累计次数降序）
    func loadSkillStats(source: AgentSource? = nil) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let stats = (try? store.toolCalls.skillStats(source: source)) ?? []
            self.publish { $0.skillStats = stats }
        }
    }

    /// 某技能按天调用序列（详情页趋势图；回调回主线程，避免跨技能发布态串味）
    func loadSkillDailySeries(
        source: AgentSource, name: String, from: Date, to: Date,
        completion: @escaping ([SkillDayCount]) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, let store = self.store else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let series = (try? store.toolCalls.dailySeries(
                source: source, kind: "skill", name: name, from: from, to: to)) ?? []
            let points = series.map { SkillDayCount(day: $0.day, count: $0.count) }
            DispatchQueue.main.async { completion(points) }
        }
    }

    /// 模型统计（选中区间的完整分项，token 降序）——同时是英雄卡/四宫格/命中率的数据源
    func loadModelTotals(from: Date, to: Date) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let totals = (try? store.usage.totalsByModel(from: from, to: to)) ?? []
            let sorted = totals.sorted {
                ($0.inputTokens + $0.outputTokens + $0.cacheReadTokens + $0.cacheCreationTokens)
                    > ($1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheCreationTokens)
            }
            self.publish { $0.modelTotals = sorted }
        }
    }

    /// 项目统计（选中区间，按项目聚合 token + 费用，token 降序）
    func loadProjectTotals(from: Date, to: Date) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let rows = (try? store.usage.totalsByProject(from: from, to: to)) ?? []
            var byProject: [String: (tokens: Int, cost: Double?)] = [:]
            for (project, totals) in rows {
                let name = project ?? "（未知项目）"
                let tokens = totals.inputTokens + totals.outputTokens
                    + totals.cacheCreationTokens + totals.cacheReadTokens
                let cost = self.pricing.cost(of: totals)
                var entry = byProject[name] ?? (0, nil)
                entry.tokens += tokens
                if let cost { entry.cost = (entry.cost ?? 0) + cost }
                byProject[name] = entry
            }
            let result = byProject
                .map { ProjectTotal(name: $0.key, tokens: $0.value.tokens, costUSD: $0.value.cost) }
                .sorted { $0.tokens > $1.tokens }
            self.publish { $0.projectTotals = result }
        }
    }

    /// 行成本折算（模型统计合计行用）
    func cost(of totals: UsageTotals) -> Double? {
        pricing.cost(of: totals)
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
            let opencodeNew = try opencodeScanner?.scanOnce() ?? 0
            HealthRegistry.shared.beat(Self.opencodeHealthName)
            if opencodeNew > 0 { HealthRegistry.shared.event(Self.opencodeHealthName) }
            let grokNew = try grokScanner?.scanOnce() ?? 0
            HealthRegistry.shared.beat(Self.grokHealthName)
            if grokNew > 0 { HealthRegistry.shared.event(Self.grokHealthName) }
            let kimiNew = try kimiScanner?.scanOnce() ?? 0
            HealthRegistry.shared.beat(Self.kimiHealthName)
            if kimiNew > 0 { HealthRegistry.shared.event(Self.kimiHealthName) }
            try store.scanState.pruneDedupKeys(
                before: Date().addingTimeInterval(-8 * 86400))
            // 全文索引与用量同节奏增量跑（指纹无变化时近零开销）；开关默认开
            if UserDefaults.standard.object(forKey: "fullTextSearchEnabled") as? Bool ?? true {
                searchIndexer?.indexOnce()
            }
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
