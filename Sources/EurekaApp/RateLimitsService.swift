import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

/// Rate-limit service: Codex / Grok (local log snapshots, zero network) + Claude (opt-in unofficial
/// API). A provider returning nil = that source's whole block is hidden. Each refresh also persists
/// one percentage sample row (limit_samples) and linearly extrapolates the "expected to be full at"
/// time; when that falls within the horizon (<90 minutes) an island card is raised via onAlert
/// (once per source per window period).
final class RateLimitsService: ObservableObject {
    @Published private(set) var codex: RateLimitSnapshot?
    @Published private(set) var grok: RateLimitSnapshot?
    @Published private(set) var claude: RateLimitSnapshot?
    /// Antigravity: no reliable local quota source yet (agy holds the live quota only in memory),
    /// always nil
    @Published private(set) var antigravity: RateLimitSnapshot?
    @Published private(set) var claudeFailureHint: String?
    /// Expected full-at time per window (key = "\(source.rawValue)#primary" / "#secondary"; absent
    /// when not at risk)
    @Published private(set) var forecasts: [String: Date] = [:]

    /// Forecast alert callback (injected by AppDelegate → Dynamic Island card)
    var onAlert: ((IslandNotice) -> Void)?

    /// The unofficial API is off by default
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
    // Grok quota works like Codex: local log snapshot, zero network, hidden on failure → no opt-in
    // needed
    private let grokProvider = GrokRateLimitProvider(logURL: GrokPaths.unifiedLog())
    private let claudeProvider = ClaudeOAuthUsageProvider()
    private var timer: Timer?
    private var refreshing = false

    private let sampleQueue = DispatchQueue(
        label: "com.vinlee.eureka.limit-samples", qos: .utility)
    /// Accessed only on sampleQueue
    private var sampleStore: EurekaStore?
    private var sampleStoreLoaded = false
    /// Keys of (source, window, reset period) already alerted: one alert per window period;
    /// accessed on main
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
            let antigravitySnapshot: RateLimitSnapshot? = nil
            let hint = wantClaude ? self.claudeProvider.lastFailure : nil
            await MainActor.run {
                self.codex = codexSnapshot
                self.grok = grokSnapshot
                self.claude = claudeSnapshot
                self.antigravity = antigravitySnapshot
                self.claudeFailureHint = hint
                self.refreshing = false
            }
            self.recordAndForecast([codexSnapshot, grokSnapshot, claudeSnapshot, antigravitySnapshot])
        }
    }

    // MARK: - Sampling and forecasting

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
            // Once per source per window period: the reset time is part of the key, so it unlocks
            // naturally once the window rolls over
            let epoch = Int(candidate.window.resetsAt?.timeIntervalSince1970 ?? 0)
            let dedupKey = "\(candidate.key)#\(epoch)"
            guard !alertedKeys.contains(dedupKey) else { continue }
            alertedKeys.insert(dedupKey)
            let label = candidate.window.label ?? Self.windowLabel(
                candidate.window.windowMinutes, isPrimary: candidate.kind == "primary")
            let timeText = eta.formatted(date: .omitted, time: .shortened)
            onAlert?(IslandNotice(
                id: "limit-\(dedupKey)",
                emoji: "⏳",
                headline: L10n.format("%@ %@ is expected to reach its limit at %@", zhHans: "%@ %@预计 %@ 打满", String(candidate.source.displayName), String(label), String(timeText)),
                body: L10n.format("Currently %@%% used, projected from recent usage. Schedule tasks accordingly; once full, you must wait for the window to reset.", zhHans: "当前已用 %@%%，按最近用量速度外推。注意安排任务，打满后需等窗口重置。", String(Int(candidate.window.usedPercent.rounded())))))
        }
    }

    /// Window duration → alert copy label (same basis as the limits panel)
    private static func windowLabel(_ minutes: Int, isPrimary: Bool) -> String {
        switch minutes {
        case 300: return L10n.text("5-hour window", zhHans: "5 小时窗口")
        case 10080: return L10n.text("Weekly window", zhHans: "每周窗口")
        case 43200: return L10n.text("Monthly window", zhHans: "每月窗口")
        default: return isPrimary ? L10n.text("Short window", zhHans: "短窗口") : L10n.text("Long window", zhHans: "长窗口")
        }
    }
}
