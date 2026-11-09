import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

/// Rate-limit service: Codex / Grok (local log snapshots, zero network) + Claude (opt-in unofficial
/// API) on a 5-minute timer, plus Antigravity (`agy /usage`) and OpenCode Go (`opencode api`) that
/// run only on demand - when the Limits page opens or the refresh button is pressed, at most once
/// per `onDemandInterval` - because each spawns the user's own CLI. A provider returning nil =
/// that source's whole block is hidden. Each refresh also persists one percentage sample row
/// (limit_samples) and linearly extrapolates the "expected to be full at" time; when that falls
/// within the horizon (<90 minutes) an island card is raised via onAlert (once per source per
/// window period).
final class RateLimitsService: ObservableObject {
    @Published private(set) var codex: RateLimitSnapshot?
    @Published private(set) var grok: RateLimitSnapshot?
    @Published private(set) var claude: RateLimitSnapshot?
    /// Antigravity quota from `agy /usage` (on demand only)
    @Published private(set) var antigravity: RateLimitSnapshot?
    /// OpenCode Go allowance from `opencode api` (on demand only; nil without Go)
    @Published private(set) var opencodeGo: RateLimitSnapshot?
    @Published private(set) var claudeFailureHint: String?
    @Published private(set) var antigravityFailureHint: String?
    /// A refresh (timer or on-demand) is in flight; drives the refresh button's spinner
    @Published private(set) var isRefreshing = false
    /// The on-demand CLI probes (agy ~5 s) are running; drives the Antigravity loading line
    @Published private(set) var isProbing = false

    /// What asked for a refresh. Only the Limits page and the refresh button run the CLI probes.
    enum RefreshTrigger {
        case background
        case pageOpen
        case manual
    }

    /// Shortest gap between two on-demand CLI probes (agy takes ~5 s and loads the user's hooks)
    static let onDemandInterval: TimeInterval = 120
    /// Expected full-at time per window (key = "\(source.rawValue)#primary" / "#secondary"; absent
    /// when not at risk)
    @Published private(set) var forecasts: [String: Date] = [:]

    /// Forecast alert callback (injected by AppDelegate → Dynamic Island card)
    var onAlert: ((IslandNotice) -> Void)?

    /// The unofficial API is off by default
    @Published var claudeEnabled: Bool = UserDefaults.standard.bool(forKey: "claudeLimitsEnabled") {
        didSet {
            // A preview render must not touch the real preference or the network
            guard !previewFrozen else { return }
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
    private let antigravityProvider = AntigravityQuotaProvider(
        probeDirectory: RateLimitsService.probeRoot.appendingPathComponent("agy", isDirectory: true))
    private let opencodeGoProvider = OpencodeGoProvider(
        probeDirectory: RateLimitsService.probeRoot.appendingPathComponent("opencode", isDirectory: true))
    private var timer: Timer?
    private var refreshing = false
    private var probing = false
    private var lastProbeAt: Date?
    /// Set by `loadPreview`: the service shows fixed snapshots and never refreshes
    private var previewFrozen = false

    private let sampleQueue = DispatchQueue(
        label: "com.vinlee.eureka.limit-samples", qos: .utility)
    /// Accessed only on sampleQueue
    private var sampleStore: EurekaStore?
    /// asOf of the last Claude answer written to limit_samples (sampleQueue only). Page opens
    /// inside the 60 s request gap return the same cached answer; sampling it again would stack
    /// copies of one reading into the forecast fit. Codex / Grok are left alone on purpose: their
    /// unchanged log snapshot re-sampled every 5 minutes is what tells the forecaster usage is flat.
    private var lastClaudeSampleAsOf: Date?
    private var sampleStoreLoaded = false
    /// Keys of (source, window, reset period) already alerted: one alert per window period;
    /// accessed on main
    private var alertedKeys: Set<String> = []

    /// UserDefaults key of the Claude provider's last answer + 429 backoff (survives relaunches)
    private static let claudeStateKey = "claudeLimitsState"

    init() {
        // A relaunch shows the last Claude numbers (as stale) at once and keeps any 429 backoff,
        // instead of hiding the card and re-knocking on a rate-limited endpoint
        if let data = UserDefaults.standard.data(forKey: Self.claudeStateKey),
           let state = try? JSONDecoder().decode(
               ClaudeOAuthUsageProvider.PersistedState.self, from: data) {
            let restored = claudeProvider.restore(state)
            if claudeEnabled {
                claude = restored
                claudeFailureHint = claudeProvider.lastFailure
            }
        }
    }

    private func saveClaudeState() {
        guard !previewFrozen,
              let data = try? JSONEncoder().encode(claudeProvider.persistedState)
        else { return }
        UserDefaults.standard.set(data, forKey: Self.claudeStateKey)
    }

    /// Working directories of the CLI probes (beside the database, never the user's folders)
    static var probeRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eureka/probes", isDirectory: true)
    }

    func start() {
        refresh(.background)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh(.background)
        }
    }

    /// Offscreen renders only: freeze the panel on fixed snapshots so every row can be drawn
    /// without real credits. Refresh becomes a no-op and nothing is persisted.
    func loadPreview(
        codex: RateLimitSnapshot?, grok: RateLimitSnapshot?, claude: RateLimitSnapshot?,
        antigravity: RateLimitSnapshot? = nil, opencodeGo: RateLimitSnapshot? = nil
    ) {
        previewFrozen = true
        self.codex = codex
        self.grok = grok
        self.claude = claude
        self.antigravity = antigravity
        self.opencodeGo = opencodeGo
        claudeFailureHint = nil
        antigravityFailureHint = nil
        claudeEnabled = claude != nil
    }

    func refresh(_ trigger: RefreshTrigger = .background) {
        guard !previewFrozen else { return }
        if trigger != .background { probeOnDemand() }
        guard !refreshing else { return }
        refreshing = true
        updateBusy()
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
                if wantClaude { self.saveClaudeState() }
                self.refreshing = false
                self.updateBusy()
            }
            self.recordAndForecast([codexSnapshot, grokSnapshot, claudeSnapshot])
        }
    }

    /// agy and opencode run in their own task so agy's ~5 s never holds back the other cards.
    /// Their windows are all scoped, so they add no forecast samples.
    private func probeOnDemand() {
        let now = Date()
        guard !probing else { return }
        if let lastProbeAt, now.timeIntervalSince(lastProbeAt) < Self.onDemandInterval { return }
        lastProbeAt = now
        probing = true
        updateBusy()
        Task { [weak self] in
            guard let self else { return }
            async let antigravity = self.antigravityProvider.snapshot()
            async let opencodeGo = self.opencodeGoProvider.snapshot()
            let (antigravitySnapshot, opencodeSnapshot) = await (antigravity, opencodeGo)
            let hint = self.antigravityProvider.lastFailure
            await MainActor.run {
                self.antigravity = antigravitySnapshot
                self.opencodeGo = opencodeSnapshot
                self.antigravityFailureHint = hint
                self.probing = false
                self.updateBusy()
            }
        }
    }

    private func updateBusy() {
        isRefreshing = refreshing || probing
        isProbing = probing
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
                if snapshot.source == .claude {
                    if snapshot.asOf == self.lastClaudeSampleAsOf { continue }
                    self.lastClaudeSampleAsOf = snapshot.asOf
                }
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
