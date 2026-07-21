import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

/// 限额服务：Codex / Grok（本地日志快照，零网络）+ Claude（opt-in 非官方接口）。
/// Provider 返回 nil = 该来源整块隐藏。
/// 每次刷新同时落一行百分比采样（limit_samples）并线性外推"预计打满时刻"，
/// 命中视距（<90 分钟）时经 onAlert 弹岛卡（每源每窗口期一次）。
final class RateLimitsService: ObservableObject {
    @Published private(set) var codex: RateLimitSnapshot?
    @Published private(set) var grok: RateLimitSnapshot?
    @Published private(set) var claude: RateLimitSnapshot?
    @Published private(set) var claudeFailureHint: String?
    /// 各窗口的预计打满时刻（key = "\(source.rawValue)#primary" / "#secondary"；无风险即缺席）
    @Published private(set) var forecasts: [String: Date] = [:]

    /// 预测告警回调（AppDelegate 注入 → 灵动岛卡片）
    var onAlert: ((IslandNotice) -> Void)?

    /// 非官方接口默认关闭
    @Published var claudeEnabled: Bool = UserDefaults.standard.bool(forKey: "claudeLimitsEnabled") {
        didSet {
            UserDefaults.standard.set(claudeEnabled, forKey: "claudeLimitsEnabled")
            if claudeEnabled {
                refresh()
            } else {
                claude = nil
                claudeFailureHint = nil
            }
        }
    }

    private let codexProvider = CodexRateLimitProvider(
        sessionsRoot: CodexRolloutTailer.defaultSessionsRoot())
    // Grok 配额同 Codex：本地日志快照、零网络、失败即隐藏 → 无需 opt-in
    private let grokProvider = GrokRateLimitProvider(logURL: GrokPaths.unifiedLog())
    private let claudeProvider = ClaudeOAuthUsageProvider()
    private var timer: Timer?
    private var refreshing = false

    private let sampleQueue = DispatchQueue(
        label: "com.vinlee.eureka.limit-samples", qos: .utility)
    /// 仅 sampleQueue 上访问
    private var sampleStore: EurekaStore?
    private var sampleStoreLoaded = false
    /// 已告警的 (source, window, 重置期) 键——每窗口期只弹一次；main 上访问
    private var alertedKeys: Set<String> = []

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let wantClaude = claudeEnabled
        Task { [weak self] in
            guard let self else { return }
            let codexSnapshot = await self.codexProvider.snapshot()
            let grokSnapshot = await self.grokProvider.snapshot()
            let claudeSnapshot = wantClaude ? await self.claudeProvider.snapshot() : nil
            let hint = wantClaude ? self.claudeProvider.lastFailure : nil
            await MainActor.run {
                self.codex = codexSnapshot
                self.grok = grokSnapshot
                self.claude = claudeSnapshot
                self.claudeFailureHint = hint
                self.refreshing = false
            }
            self.recordAndForecast([codexSnapshot, grokSnapshot, claudeSnapshot])
        }
    }

    // MARK: - 采样与预测

    private func recordAndForecast(_ snapshots: [RateLimitSnapshot?]) {
        sampleQueue.async { [weak self] in
            guard let self else { return }
            if !self.sampleStoreLoaded {
                self.sampleStoreLoaded = true
                self.sampleStore = try? EurekaStore(path: EurekaStore.defaultURL())
            }
            guard let store = self.sampleStore else { return }
            let now = Date()
            var forecasts: [String: Date] = [:]
            var candidates: [(key: String, source: AgentSource,
                              window: RateLimitWindow, kind: String)] = []
            for snapshot in snapshots {
                guard let snapshot, !snapshot.isStale else { continue }
                let windows: [(String, RateLimitWindow?)] = [
                    ("primary", snapshot.primary), ("secondary", snapshot.secondary),
                ]
                for (kind, window) in windows {
                    guard let window else { continue }
                    let sourceKey = snapshot.source.rawValue
                    try? store.limitSamples.insert(
                        source: sourceKey, window: kind,
                        percent: window.usedPercent, ts: now)
                    let history = (try? store.limitSamples.samples(
                        source: sourceKey, window: kind,
                        since: now.addingTimeInterval(-2 * 3600))) ?? []
                    let points = history.map {
                        LimitForecaster.Point(ts: $0.ts, percent: $0.percent)
                    }
                    if let eta = LimitForecaster.forecastFullAt(points: points, now: now) {
                        let key = "\(sourceKey)#\(kind)"
                        forecasts[key] = eta
                        candidates.append((key, snapshot.source, window, kind))
                    }
                }
            }
            try? store.limitSamples.prune(before: now.addingTimeInterval(-14 * 86400))
            DispatchQueue.main.async {
                self.forecasts = forecasts
                self.fireAlerts(candidates: candidates, forecasts: forecasts)
            }
        }
    }

    private func fireAlerts(
        candidates: [(key: String, source: AgentSource,
                      window: RateLimitWindow, kind: String)],
        forecasts: [String: Date]
    ) {
        guard UserDefaults.standard.object(forKey: "limitAlertsEnabled") as? Bool ?? true
        else { return }
        for candidate in candidates {
            guard let eta = forecasts[candidate.key] else { continue }
            // 每源每窗口期一次：重置时刻进 key，窗口翻转后自然解锁
            let epoch = Int(candidate.window.resetsAt?.timeIntervalSince1970 ?? 0)
            let dedupKey = "\(candidate.key)#\(epoch)"
            guard !alertedKeys.contains(dedupKey) else { continue }
            alertedKeys.insert(dedupKey)
            let label = Self.windowLabel(candidate.window.windowMinutes,
                                         isPrimary: candidate.kind == "primary")
            let timeText = eta.formatted(date: .omitted, time: .shortened)
            onAlert?(IslandNotice(
                id: "limit-\(dedupKey)",
                emoji: "⏳",
                headline: "\(candidate.source.displayName) \(label)预计 \(timeText) 打满",
                body: "当前已用 \(Int(candidate.window.usedPercent.rounded()))%，"
                    + "按最近用量速度外推。注意安排任务，打满后需等窗口重置。"))
        }
    }

    /// 窗口时长 → 告警文案标签（与限额面板口径一致）
    private static func windowLabel(_ minutes: Int, isPrimary: Bool) -> String {
        switch minutes {
        case 300: return "5 小时窗口"
        case 10080: return "每周窗口"
        case 43200: return "每月窗口"
        default: return isPrimary ? "短窗口" : "长窗口"
        }
    }
}
