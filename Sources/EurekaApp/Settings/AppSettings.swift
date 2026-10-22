import EurekaKit
import Foundation
import ServiceManagement

/// User-defined sync folder (backup's chosen folder → remote `custom/<name>`)
struct CustomSyncFolder: Codable, Equatable, Identifiable {
    var id = UUID()
    var path: String
    var remoteName: String
    var enabled = true

    /// Remote category: `custom/<sanitized remote name>` (slashes and surrounding whitespace
    /// stripped; an empty name falls back to the folder name)
    var remoteCategory: String {
        let cleaned = remoteName
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = URL(fileURLWithPath: path).lastPathComponent
        return "custom/" + (cleaned.isEmpty ? fallback : cleaned)
    }
}

/// User preferences (persisted in UserDefaults)
@MainActor
final class AppSettings: ObservableObject {
    @Published var notifyCompletion: Bool {
        didSet { defaults.set(notifyCompletion, forKey: "notifyCompletion") }
    }
    @Published var notifyWaiting: Bool {
        didSet { defaults.set(notifyWaiting, forKey: "notifyWaiting") }
    }
    @Published var notifyError: Bool {
        didSet { defaults.set(notifyError, forKey: "notifyError") }
    }
    /// Answer Claude's questions (AskUserQuestion) on the island. On by default; when on and Claude
    /// hooks are installed, settings.json gets an extra `lululumei-ask` hook
    @Published var answerQuestionsOnIsland: Bool {
        didSet { defaults.set(answerQuestionsOnIsland, forKey: "answerQuestionsOnIsland") }
    }
    /// Also send a system notification for key events (finished/waiting/error), visible on the lock
    /// screen / other desktops. Off by default, opt-in; authorization is requested only when
    /// enabled; still gated by the per-type toggles above.
    @Published var eventSystemNotifyEnabled: Bool {
        didSet { defaults.set(eventSystemNotifyEnabled, forKey: "eventSystemNotifyEnabled") }
    }
    @Published var autoDismissSeconds: Double {
        didSet { defaults.set(autoDismissSeconds, forKey: "autoDismissSeconds") }
    }
    /// Island time display: false = elapsed duration, true = start date and time
    @Published var showStartTime: Bool {
        didSet { defaults.set(showStartTime, forKey: "islandShowStartTime") }
    }
    /// Show the rate-limit percentage in the menu-bar title
    @Published var menuBarShowsLimit: Bool {
        didSet { defaults.set(menuBarShowsLimit, forKey: "menuBarShowsLimit") }
    }
    /// Health nudges (active too long / too many sessions / late-night care)
    @Published var wellnessEnabled: Bool {
        didSet { defaults.set(wellnessEnabled, forKey: "wellnessEnabled") }
    }
    /// Remind after this many hours of continuous activity
    @Published var wellnessThresholdHours: Double {
        didSet { defaults.set(wellnessThresholdHours, forKey: "wellnessThresholdHours") }
    }
    /// Max number of sessions the session panel shows, by time (0 = all)
    /// Cross-session full-text search index (when off the index freezes and stops updating;
    /// UsageService's scan loop reads the same key)
    @Published var fullTextSearchEnabled: Bool {
        didSet { defaults.set(fullTextSearchEnabled, forKey: "fullTextSearchEnabled") }
    }
    /// Antigravity usage / rate limits (experimental, off by default; reads undocumented protobuf)
    @Published var antigravityExperimentalEnabled: Bool {
        didSet { defaults.set(antigravityExperimentalEnabled, forKey: AntigravityExperiment.key) }
    }
    /// Fetch model prices online (LiteLLM / models.dev public price tables; PricingCatalogService
    /// reads the same key)
    @Published var remotePricingEnabled: Bool {
        didSet { defaults.set(remotePricingEnabled, forKey: "remotePricingEnabled") }
    }
    /// Island card warning when a rate limit is close to full (RateLimitsService reads the same key
    /// when alerting)
    @Published var limitAlertsEnabled: Bool {
        didSet { defaults.set(limitAlertsEnabled, forKey: "limitAlertsEnabled") }
    }
    /// After an app upgrade, automatically refresh hooks that are **already installed** to the
    /// current version.
    ///
    /// Only this **policy** is stored. The sole source of truth for "is X installed" is the config
    /// file on disk; never store an intent boolean here — it would drift from disk state and we
    /// would then edit the user's files based on stale state. Even when on, it never installs an
    /// integration the user hasn't enabled, and skips entirely on any config it can't parse.
    @Published var hookAutoUpdate: Bool {
        didSet { defaults.set(hookAutoUpdate, forKey: "hookAutoUpdate") }
    }
    /// Skip the finished card while you are looking at the terminal app the session runs in
    /// (default **off**).
    ///
    /// Detection is **app-level** only and can't tell tabs apart: with several tabs open, any one
    /// in front counts as "you're looking". So the waiting-for-permission card is **never
    /// silenced** — it is a blocking prompt that needs your action, and hiding it because "some
    /// iTerm tab is in front" does real harm (see AppDelegate.shouldSuppressCard).
    @Published var suppressCardWhenTerminalFrontmost: Bool {
        didSet {
            defaults.set(suppressCardWhenTerminalFrontmost,
                         forKey: "suppressCardWhenTerminalFrontmost")
        }
    }
    /// Sessions page time range: false = last 30 days (default); true = all time
    @Published var sessionRangeAll: Bool {
        didSet { defaults.set(sessionRangeAll, forKey: "sessionRangeAll") }
    }
    /// History list sort: active = most recently active / start = first conversation start time
    /// (stores rawValue)
    @Published var historySortMode: String {
        didSet { defaults.set(historySortMode, forKey: "historySortMode") }
    }
    /// Session list sort: time = most recently active / size = by size / duration = by duration
    /// (stores rawValue)
    @Published var sessionSortMode: String {
        didSet { defaults.set(sessionSortMode, forKey: "sessionSortMode") }
    }
    /// Appearance: system = follow system / light / dark
    @Published var appearanceMode: String {
        didSet { defaults.set(appearanceMode, forKey: "appearanceMode") }
    }
    /// Interface language (`AppLanguage` rawValue). Defaults to English. didSet syncs
    /// `L10n.current` and tells the main menu and the Dynamic Island to redraw. didSet doesn't fire
    /// in init, so sync once more at the end.
    @Published var appLanguage: String {
        didSet {
            defaults.set(appLanguage, forKey: AppLanguage.defaultsKey)
            L10n.current = AppLanguage.resolve(appLanguage)
            NotificationCenter.default.post(name: .eurekaLanguageDidChange, object: nil)
        }
    }
    /// Interface style: classic (default) / brutal = Neo-Brutalism (after raft.build). didSet syncs
    /// ThemeStyle.current; together with the root view's .id rebuilding the whole tree, it takes
    /// effect immediately.
    @Published var themeStyle: String {
        didSet {
            defaults.set(themeStyle, forKey: "themeStyle")
            ThemeStyle.current = ThemeStyle.resolve(themeStyle)
        }
    }
    /// Desktop mascot (off by default, opt-in)
    @Published var mascotEnabled: Bool {
        didSet { defaults.set(mascotEnabled, forKey: "mascotEnabled") }
    }
    /// Current mascot animation pack id ("built-in" or a directory name under mascots/)
    @Published var mascotPack: String {
        didSet { defaults.set(mascotPack, forKey: "mascotPack") }
    }
    /// Idle minutes before the companion falls asleep; 0 = never
    @Published var mascotSleepMinutes: Int {
        didSet { defaults.set(mascotSleepMinutes, forKey: "mascotSleepMinutes") }
    }
    /// Late-night mode (23:00-06:00): drowsy while working, asleep when idle
    @Published var mascotNightMode: Bool {
        didSet { defaults.set(mascotNightMode, forKey: "mascotNightMode") }
    }
    /// Speech bubbles on finish / error / wellness nudges
    @Published var mascotBubbles: Bool {
        didSet { defaults.set(mascotBubbles, forKey: "mascotBubbles") }
    }
    /// Monthly budget in USD across every source (API-equivalent cost); 0 = no budget
    @Published var usageMonthlyBudget: Double {
        didSet { defaults.set(usageMonthlyBudget, forKey: "usageMonthlyBudget") }
    }
    /// Monthly subscription price per source (`AgentSource.rawValue` → USD), for payback
    @Published var subscriptionPrices: [String: Double] {
        didSet { defaults.set(subscriptionPrices, forKey: "subscriptionPrices") }
    }
    /// Companion size (`MascotSize` raw value)
    @Published var mascotSize: String {
        didSet { defaults.set(mascotSize, forKey: "mascotSize") }
    }
    /// Cloud backup (off by default, opt-in; secrets live in the Keychain, never in UserDefaults)
    @Published var cloudBackupEnabled: Bool {
        didSet { defaults.set(cloudBackupEnabled, forKey: "cloudBackupEnabled") }
    }
    /// Storage provider (StorageProvider rawValue)
    @Published var storageProvider: String {
        didSet { defaults.set(storageProvider, forKey: "storageProvider") }
    }
    /// COS region (e.g. ap-guangzhou)
    @Published var cosRegion: String {
        didSet { defaults.set(cosRegion, forKey: "cosRegion") }
    }
    /// COS bucket (e.g. backup-1250000000)
    @Published var cosBucket: String {
        didSet { defaults.set(cosBucket, forKey: "cosBucket") }
    }
    /// Custom endpoint host (empty = COS default; for AWS use s3.<region>.amazonaws.com)
    @Published var cosEndpointHost: String {
        didSet { defaults.set(cosEndpointHost, forKey: "cosEndpointHost") }
    }
    /// Object key prefix
    @Published var cosKeyPrefix: String {
        didSet { defaults.set(cosKeyPrefix, forKey: "cosKeyPrefix") }
    }
    /// Incremental sync interval (minutes, minimum 1)
    @Published var cosSyncIntervalMinutes: Double {
        didSet { defaults.set(cosSyncIntervalMinutes, forKey: "cosSyncIntervalMinutes") }
    }
    /// Retry count for a failed backup file (0 = off; only network errors / 5xx are retried)
    @Published var cosRetryAttempts: Int {
        didSet { defaults.set(cosRetryAttempts, forKey: "cosRetryAttempts") }
    }
    /// Retry backoff base (seconds, exponential ×2)
    @Published var cosRetryBackoffSeconds: Double {
        didSet { defaults.set(cosRetryBackoffSeconds, forKey: "cosRetryBackoffSeconds") }
    }
    /// Custom sync folders (JSON-encoded in UserDefaults — the repo's first array-valued setting)
    @Published var customSyncFolders: [CustomSyncFolder] {
        didSet {
            if let data = try? JSONEncoder().encode(customSyncFolders) {
                defaults.set(data, forKey: "customSyncFolders")
            }
        }
    }
    /// Security audit: records operations agents perform (full command text / file paths, no
    /// output). On by default.
    @Published var auditEnabled: Bool {
        didSet { defaults.set(auditEnabled, forKey: "auditEnabled") }
    }
    /// Red in-island card alert for high-risk operations. On by default.
    @Published var auditRiskAlertsEnabled: Bool {
        didSet { defaults.set(auditRiskAlertsEnabled, forKey: "auditRiskAlertsEnabled") }
    }
    /// System notification for high-risk operations (visible on the lock screen / other Spaces).
    /// Off by default, opt-in; authorization is requested only when enabled.
    @Published var auditSystemNotifyEnabled: Bool {
        didSet { defaults.set(auditSystemNotifyEnabled, forKey: "auditSystemNotifyEnabled") }
    }
    /// Audit log retention in days (0 = forever). Default 90.
    /// Audit archive: writes redacted audit records as daily Parquet files uploaded with backups
    /// (off by default; requires cloud backup)
    @Published var auditArchiveEnabled: Bool {
        didSet { defaults.set(auditArchiveEnabled, forKey: AuditArchiveSettings.key) }
    }
    @Published var auditRetentionDays: Int {
        didSet { defaults.set(auditRetentionDays, forKey: "auditRetentionDays") }
    }
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginHint: String?

    private let defaults: UserDefaults

    /// `defaults` is injectable so offscreen renders can stage settings without touching the
    /// user's real preferences
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notifyCompletion = defaults.object(forKey: "notifyCompletion") as? Bool ?? true
        notifyWaiting = defaults.object(forKey: "notifyWaiting") as? Bool ?? true
        notifyError = defaults.object(forKey: "notifyError") as? Bool ?? true
        answerQuestionsOnIsland = defaults.object(forKey: "answerQuestionsOnIsland") as? Bool ?? true
        eventSystemNotifyEnabled = defaults.bool(forKey: "eventSystemNotifyEnabled")
        autoDismissSeconds = defaults.object(forKey: "autoDismissSeconds") as? Double ?? 6
        showStartTime = defaults.bool(forKey: "islandShowStartTime")
        menuBarShowsLimit = defaults.object(forKey: "menuBarShowsLimit") as? Bool ?? true
        wellnessEnabled = defaults.object(forKey: "wellnessEnabled") as? Bool ?? true
        wellnessThresholdHours = defaults.object(forKey: "wellnessThresholdHours") as? Double ?? 2
        fullTextSearchEnabled = defaults.object(forKey: "fullTextSearchEnabled") as? Bool ?? true
        remotePricingEnabled = defaults.object(forKey: "remotePricingEnabled") as? Bool ?? true
        antigravityExperimentalEnabled = defaults.bool(forKey: AntigravityExperiment.key)
        limitAlertsEnabled = defaults.object(forKey: "limitAlertsEnabled") as? Bool ?? true
        hookAutoUpdate = defaults.object(forKey: "hookAutoUpdate") as? Bool ?? true
        suppressCardWhenTerminalFrontmost = defaults.object(
            forKey: "suppressCardWhenTerminalFrontmost") as? Bool ?? false
        sessionRangeAll = defaults.bool(forKey: "sessionRangeAll")
        historySortMode = defaults.string(forKey: "historySortMode") ?? "active"
        sessionSortMode = defaults.string(forKey: "sessionSortMode") ?? "time"
        appearanceMode = defaults.string(forKey: "appearanceMode") ?? "system"
        appLanguage = AppLanguage.resolve(defaults.string(forKey: AppLanguage.defaultsKey)).rawValue
        themeStyle = defaults.string(forKey: "themeStyle") ?? ThemeStyle.classic.rawValue
        mascotEnabled = defaults.bool(forKey: "mascotEnabled")
        mascotPack = defaults.string(forKey: "mascotPack") ?? "built-in"
        mascotSleepMinutes = defaults.object(forKey: "mascotSleepMinutes") as? Int ?? 5
        mascotNightMode = defaults.object(forKey: "mascotNightMode") as? Bool ?? true
        mascotBubbles = defaults.object(forKey: "mascotBubbles") as? Bool ?? true
        mascotSize = defaults.string(forKey: "mascotSize") ?? MascotSize.medium.rawValue
        usageMonthlyBudget = defaults.object(forKey: "usageMonthlyBudget") as? Double ?? 0
        subscriptionPrices = defaults.dictionary(forKey: "subscriptionPrices") as? [String: Double] ?? [:]
        cloudBackupEnabled = defaults.bool(forKey: "cloudBackupEnabled")
        storageProvider = defaults.string(forKey: "storageProvider") ?? "tencent-cos"
        cosRegion = defaults.string(forKey: "cosRegion") ?? ""
        cosBucket = defaults.string(forKey: "cosBucket") ?? ""
        cosEndpointHost = defaults.string(forKey: "cosEndpointHost") ?? ""
        cosKeyPrefix = defaults.string(forKey: "cosKeyPrefix") ?? "eureka"
        cosSyncIntervalMinutes = max(
            1, defaults.object(forKey: "cosSyncIntervalMinutes") as? Double ?? 30)
        cosRetryAttempts = defaults.object(forKey: "cosRetryAttempts") as? Int ?? 2
        cosRetryBackoffSeconds =
            defaults.object(forKey: "cosRetryBackoffSeconds") as? Double ?? 3
        customSyncFolders = defaults.data(forKey: "customSyncFolders")
            .flatMap { try? JSONDecoder().decode([CustomSyncFolder].self, from: $0) } ?? []
        auditEnabled = defaults.object(forKey: "auditEnabled") as? Bool ?? true
        auditRiskAlertsEnabled = defaults.object(forKey: "auditRiskAlertsEnabled") as? Bool ?? true
        auditSystemNotifyEnabled = defaults.bool(forKey: "auditSystemNotifyEnabled")
        auditRetentionDays = defaults.object(forKey: "auditRetentionDays") as? Int ?? 90
        auditArchiveEnabled = defaults.bool(forKey: AuditArchiveSettings.key)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        // Sync interface style and language at startup (didSet doesn't fire in init, so sync
        // explicitly once every property is initialized)
        ThemeStyle.current = ThemeStyle.resolve(themeStyle)
        L10n.current = AppLanguage.resolve(appLanguage)
    }

    /// SMAppService registration may be flaky for ad-hoc / dev builds: on failure show a degraded
    /// hint instead of failing silently
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginHint = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginHint = L10n.format(
                "Registration failed (%@). Run make install into ~/Applications first, or add the app under System Settings > General > Login Items.",
                zhHans: "注册失败（%@）。请先 make install 安装到 ~/Applications 后再开启，或在 系统设置 > 通用 > 登录项 手动添加。",
                error.localizedDescription)
        }
    }
}

/// Antigravity experiment toggle (UsageService / RateLimitsService read UserDefaults directly on
/// their own queues)
enum AntigravityExperiment {
    static let key = "antigravityExperimentalEnabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }
}

/// Audit archive toggle (SyncService / AuditService read UserDefaults directly on their own queues)
enum AuditArchiveSettings {
    static let key = "auditArchiveEnabled"

    /// Only effective when backup is also on: with backup off nothing gets uploaded, and the linked
    /// pruning would let local data grow without bound
    static var isActive: Bool {
        UserDefaults.standard.bool(forKey: key) && UserDefaults.standard.bool(forKey: "cloudBackupEnabled")
    }

    /// Audit retention cutoff (0 = keep forever → nil)
    static var retentionCutoff: Date? {
        let days = UserDefaults.standard.object(forKey: "auditRetentionDays") as? Int ?? 90
        return days > 0 ? Date().addingTimeInterval(-Double(days) * 86400) : nil
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
