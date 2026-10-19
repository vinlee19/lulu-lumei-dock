import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaSync
import EurekaUsage
import Foundation

/// Cloud backup service: incremental uploads on a timer (30 minutes) + manual trigger. All IO
/// (Keychain subprocess, file enumeration, network uploads, SQLite) runs on a private utility
/// queue; @Published state is published back on the main thread (mirrors UsageService's pattern).
final class SyncService: ObservableObject {
    @Published private(set) var syncing = false
    @Published private(set) var lastResult: String?
    @Published private(set) var lastError: String?
    @Published private(set) var credentialsConfigured = false
    @Published private(set) var connectionTest: ConnectionTest?
    /// Live progress of the running sync (nil = idle)
    @Published private(set) var progress: SyncProgress?
    /// Current page of sync history (persisted, newest first) and total run count (for paging)
    @Published private(set) var runs: [SyncRunsRepo.Run] = []
    @Published private(set) var runsTotal = 0
    /// Total backup stats (aggregated from sync_state)
    @Published private(set) var stats: SyncStateRepo.Stats?
    /// Backup composition by source (remote_key source segment → file count/bytes; for the
    /// "composition" chips)
    @Published private(set) var sourceComposition: [String: (count: Int, bytes: Int64)] = [:]
    /// Backup composition (two levels: source → category), for the backup page's composition
    /// section
    @Published private(set) var composition: [SyncStateRepo.CompositionBucket] = []
    /// Current sync interval (minutes, read-only display) History page the view is currently
    /// showing (synced from BackupView, so that page refreshes in place after each sync)
    var visibleRunsPage = 1
    @Published private(set) var intervalMinutes: Double = 30

    private let queue = DispatchQueue(label: "com.vinlee.eureka.sync", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// Accessed only on queue: skip-if-syncing guard
    private var running = false
    /// Config snapshotted from the main thread at the start of each run
    private struct Config {
        var provider: StorageProvider
        var region: String
        var bucket: String
        var endpointHost: String  // only used when provider == .custom
        var keyPrefix: String
        /// Per-file failure retry count (0 = off) and backoff base (seconds, exponential ×2)
        var retryAttempts = 2
        var retryBackoffSeconds: Double = 3
        /// User-defined sync folders (only enabled ones go into roots)
        var customFolders: [CustomSyncFolder] = []

        /// Resolves the endpoint host from the provider preset; custom uses the user's value (empty
        /// = not configured)
        var resolvedEndpointHost: String {
            provider.endpointHost(region: region) ?? endpointHost
        }
    }
    private var config = Config(
        provider: .tencentCOS, region: "", bucket: "", endpointHost: "", keyPrefix: "eureka")

    private static let healthName = "云端备份"
    /// Incremental sync interval (seconds), injected from settings (minimum 1 minute), default 30
    /// minutes
    private var intervalSeconds: TimeInterval = 1800

    // MARK: - Lifecycle

    /// Starts the timer when the toggle is on (the first fire is delayed to avoid the launch-scan
    /// peak, but by no more than one interval)
    func start() {
        guard timer == nil else { return }
        HealthRegistry.shared.register(Self.healthName, expectedInterval: intervalSeconds)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // leeway lets the system coalesce wakeups to save power; it must be less than the sync
        // interval
        let leeway: DispatchTimeInterval = intervalSeconds >= 2
            ? .milliseconds(500) : .milliseconds(100)
        timer.schedule(
            deadline: .now() + min(120, intervalSeconds),
            repeating: intervalSeconds, leeway: leeway)
        timer.setEventHandler { [weak self] in
            self?.runCycleIfIdle(limits: SyncEngine.Limits())
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Updates the sync interval (minutes, minimum 1); a running timer is rescheduled immediately
    /// at the new interval
    func updateInterval(minutes: Double) {
        let seconds = max(60, minutes * 60)
        intervalMinutes = seconds / 60
        guard seconds != intervalSeconds else { return }
        intervalSeconds = seconds
        if timer != nil {
            stop()
            start()
        }
    }

    /// Refreshes total backup stats (called on the Backup tab's onAppear + after each sync)
    func refreshStats() {
        queue.async { [weak self] in
            guard let self,
                  let store = try? EurekaStore(path: EurekaStore.defaultURL()),
                  let stats = try? store.syncState.stats()
            else { return }
            let buckets = (try? store.syncState.composition()) ?? []
            var bySource: [String: (count: Int, bytes: Int64)] = [:]
            for bucket in buckets {
                var entry = bySource[bucket.source] ?? (0, 0)
                entry.count += bucket.count
                entry.bytes += bucket.bytes
                bySource[bucket.source] = entry
            }
            self.publish {
                $0.stats = stats
                $0.sourceComposition = bySource
                $0.composition = buckets
            }
        }
    }

    /// Paged loading of sync history (page starts at 1)
    func loadRuns(page: Int, pageSize: Int = 20) {
        queue.async { [weak self] in
            guard let self,
                  let store = try? EurekaStore(path: EurekaStore.defaultURL())
            else { return }
            let total = (try? store.syncRuns.count()) ?? 0
            let runs = (try? store.syncRuns.recent(
                limit: pageSize, offset: (max(1, page) - 1) * pageSize)) ?? []
            self.publish {
                $0.runs = runs
                $0.runsTotal = total
            }
        }
    }

    /// Called from the UI side when config changes (each run reads the latest snapshot)
    func updateConfig(
        provider: StorageProvider, region: String, bucket: String,
        endpointHost: String, keyPrefix: String,
        retryAttempts: Int = 2, retryBackoffSeconds: Double = 3,
        customFolders: [CustomSyncFolder] = []
    ) {
        queue.async { [weak self] in
            self?.config = Config(
                provider: provider, region: region, bucket: bucket,
                endpointHost: endpointHost, keyPrefix: keyPrefix,
                retryAttempts: retryAttempts,
                retryBackoffSeconds: retryBackoffSeconds,
                customFolders: customFolders)
        }
    }

    // MARK: - Actions (all queue.async)

    /// Manual "Sync now": relaxes quotas to upload as much as possible in one go
    func syncNow() {
        queue.async { [weak self] in
            self?.runCycleIfIdle(limits: .relaxed)
        }
    }

    /// Outcome of the last HEAD-bucket probe. A typed state rather than a message string so the
    /// view can give success, failure and "still running" different colours and a spinner.
    enum ConnectionTest: Equatable {
        case running
        case success
        case failure(String)
    }

    /// HEAD Bucket to test the connection/credentials
    func testConnection() {
        publish { $0.connectionTest = .running }
        queue.async { [weak self] in
            guard let self else { return }
            guard let client = self.makeClient() else {
                self.publish { $0.connectionTest = .failure(L10n.text("Incomplete configuration: enter the region and bucket, and save your credentials", zhHans: "配置不完整：请填写地域、存储桶并保存密钥")) }
                return
            }
            do {
                try client.headBucket()
                self.publish { $0.connectionTest = .success }
            } catch {
                self.publish { $0.connectionTest = .failure(L10n.format("Connection failed: %@", zhHans: "连接失败：%@", String(describing: error))) }
            }
        }
    }

    func saveCredentials(secretId: String, secretKey: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            let okId = KeychainStore.write(
                account: KeychainStore.secretIdAccount, secret: secretId)
            let okKey = KeychainStore.write(
                account: KeychainStore.secretKeyAccount, secret: secretKey)
            let ok = okId && okKey
            self?.publish {
                $0.credentialsConfigured = ok
                if !ok { $0.lastError = L10n.text("Failed to save credentials to Keychain", zhHans: "密钥写入钥匙串失败") }
            }
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    /// Probes Keychain state when the settings page appears (in the background, not blocking the
    /// UI)
    func refreshCredentialStatus() {
        queue.async { [weak self] in
            let configured = KeychainStore.read(account: KeychainStore.secretIdAccount) != nil
                && KeychainStore.read(account: KeychainStore.secretKeyAccount) != nil
            self?.publish { $0.credentialsConfigured = configured }
        }
    }

    // MARK: - Sync loop (runs on queue)

    private func runCycleIfIdle(limits: SyncEngine.Limits) {
        guard !running else { return }
        running = true
        defer { running = false }
        HealthRegistry.shared.beat(Self.healthName)
        publish { $0.syncing = true; $0.lastError = nil }
        defer { publish { $0.syncing = false } }

        guard let client = makeClient() else {
            publish { $0.lastError = L10n.text("Backup did not run: enter the region and bucket, and save your credentials", zhHans: "备份未运行：请填写地域、存储桶并保存密钥") }
            return
        }
        guard let store = try? EurekaStore(path: EurekaStore.defaultURL()) else {
            publish { $0.lastError = L10n.text("Backup failed: local database unavailable", zhHans: "备份失败：本地数据库不可用") }
            HealthRegistry.shared.failure(Self.healthName, note: L10n.text("Failed to open sqlite", zhHans: "sqlite 打开失败"))
            return
        }

        Self.materializePlans()  // materialize Codex/opencode/Grok/Kimi plans into staging so this run's incremental upload includes them

        // eureka analytics snapshot: rebuilt only when the three fact tables' fingerprints change
        // (see the EurekaDBSnapshot header comment -- uploading the whole DB would self-trigger via
        // sync_state bookkeeping into an upload every run). Server-side analytics scripts are in
        // Scripts/analytics/.
        let snapshotURL = Self.eurekaSnapshotURL()
        EurekaDBSnapshot.materializeIfChanged(
            dbPath: EurekaStore.defaultURL(), snapshotPath: snapshotURL)

        // Retry parameters and custom folders come from the config snapshot
        var effectiveLimits = limits
        effectiveLimits.maxRetries = config.retryAttempts
        effectiveLimits.retryBackoffSeconds = config.retryBackoffSeconds
        var roots = Self.defaultRoots()
        roots.customDirs = config.customFolders
            .filter { $0.enabled && !$0.path.isEmpty }
            .map { folder in
                (root: URL(fileURLWithPath: folder.path, isDirectory: true),
                 category: folder.remoteCategory)
            }
        roots.traeRoots = Self.traeRoots()
        if FileManager.default.fileExists(atPath: snapshotURL.path) {
            roots.eurekaSnapshot = snapshotURL
        }
        // Audit archive: redacted and written as Parquet per UTC day (only days whose fingerprint
        // changed are rewritten), uploaded with this run
        let archiveActive = AuditArchiveSettings.isActive
        let archiveCutoff = AuditArchiveSettings.retentionCutoff
        if archiveActive {
            let outcome = AuditArchive.materialize(
                store: store, outDir: Self.auditArchiveDir(), host: SyncKeyMapper.deviceNamespace(),
                appVersion: AuditArchiveSettings.appVersion, cutoff: archiveCutoff)
            if let error = outcome.errors.first {
                HealthRegistry.shared.failure(Self.healthName, note: L10n.format("Audit archive: %@", zhHans: "审计归档：%@", String(describing: error)))
            }
            roots.auditArchiveDir = Self.auditArchiveDir()
        }
        // Project-level skills are included in backups (reuses the Skills page's project discovery;
        // category <source>/skills/project/<project name>)
        roots.projectSkills = SkillMemoryIndexer
            .projectSkillRoots(repoRoots: ProjectScopeDiscovery.repoRoots(resolver: ProjectResolver()))
            .map { (root: $0.root, category: "\($0.source.rawValue)/skills/project/\($0.projectName)") }

        let engine = SyncEngine(
            client: client, repo: store.syncState, roots: roots,
            keyPrefix: config.keyPrefix.isEmpty ? "eureka" : config.keyPrefix,
            host: SyncKeyMapper.deviceNamespace(), limits: effectiveLimits)
        engine.onProgress = { [weak self] snapshot in
            self?.publish { $0.progress = snapshot }
        }
        let report = engine.runCycle()
        publish { $0.progress = nil }
        if archiveActive {
            // Record uploaded days in the ledger (the audit page uses it to allow local cleanup);
            // expired and uploaded local files are deleted, the remote copy is kept
            AuditArchive.reconcileUploads(store: store)
            if let archiveCutoff {
                AuditArchive.removeUploadedLocalFiles(store: store, cutoff: archiveCutoff)
            }
        }

        if report.uploaded > 0 {
            HealthRegistry.shared.event(Self.healthName)
        }
        if let error = report.firstError {
            HealthRegistry.shared.failure(Self.healthName, note: error)
        }
        // Record a run only when something actually happened (skip empty runs with no changes),
        // then prune after persisting
        if report.uploaded > 0 || report.failed > 0 {
            try? store.syncRuns.insert(
                date: Date(), uploaded: report.uploaded, uploadedBytes: report.uploadedBytes,
                failed: report.failed, deferred: report.deferred, error: report.firstError,
                files: report.uploadedFiles.map {
                    SyncRunsRepo.RunFile(name: $0.name, size: $0.size, category: $0.category)
                })
            try? store.syncRuns.prune(keepingLast: 200)
        }
        publish {
            $0.lastResult = Self.describe(report)
            $0.lastError = report.firstError.map { L10n.format("Partially failed (%@ files): %@", zhHans: "部分失败（%@ 个）：%@", String(report.failed), String($0)) }
        }
        // Only refresh the list when the user is currently on page 1: otherwise it would bounce
        // them off the page they paged to (the view owns historyPage itself; a forced refresh from
        // the service would put the two out of sync)
        loadRuns(page: visibleRunsPage)
        refreshStats()
    }

    private func makeClient() -> S3Client? {
        let host = config.resolvedEndpointHost
        guard !config.region.isEmpty, !config.bucket.isEmpty, !host.isEmpty,
              let secretId = KeychainStore.read(account: KeychainStore.secretIdAccount),
              let secretKey = KeychainStore.read(account: KeychainStore.secretKeyAccount)
        else { return nil }
        return S3Client(
            config: S3Config(
                region: config.region, bucket: config.bucket, endpointHost: host),
            credentials: SigV4Signer.Credentials(accessKey: secretId, secretKey: secretKey))
    }

    static func defaultRoots() -> SyncRoots {
        SyncRoots(
            claudeHome: SkillMemoryIndexer.claudeHome(),
            claudeProjects: ClaudeSessionBootstrap.defaultProjectsRoot(),
            claudeSkills: SkillMemoryIndexer.claudeSkillsRoot(),
            codexHome: SkillMemoryIndexer.codexHome(),
            codexSessions: CodexRolloutTailer.defaultSessionsRoot(),
            codexSkills: SkillMemoryIndexer.codexSkillsRoot(),
            opencodeSkills: OpencodePaths.skillsRoot(),
            opencodeDB: OpencodePaths.db(),
            grokSkills: GrokPaths.skillsRoot(),
            grokMemory: GrokPaths.memoryRoot(),
            grokSessions: GrokPaths.sessionsRoot(),
            kimiSkills: KimiPaths.skillsRoot(),
            kimiSessions: KimiPaths.sessionsRoot(),
            geminiHome: GeminiPaths.configHome(),
            geminiSessions: GeminiPaths.tmpRoot(),
            geminiSkills: GeminiPaths.skillsRoot(),
            qwenProjects: QwenPaths.projectsRoot(),
            qwenMemories: QwenPaths.memoriesRoot(),
            qwenSkills: QwenPaths.skillsRoot(),
            hermesSkills: HermesPaths.skillsRoot(),
            hermesMemories: HermesPaths.memoriesRoot(),
            hermesHome: HermesPaths.configHome(),
            hermesPlans: HermesPaths.plansRoot(),
            claudePlans: PlanMaterializer.defaultClaudePlansDir(),
            plansStaging: PlanMaterializer.defaultStagingRoot(),
            codeBuddyProjects: CodeBuddyPaths.projectsRoot(),
            codeBuddyMemory: CodeBuddyPaths.memoryRoot(),
            qoderProjects: QoderPaths.projectsRoot(),
            qoderMemories: QoderPaths.memoriesRoot(),
            cursorSkills: CursorPaths.skillsRoot(),
            cursorAgents: CursorPaths.agentsRoot(),
            zcodeRollout: ZcodePaths.rolloutRoot(),
            zcodeAgents: ZcodePaths.agentsRoot(),
            zcodeSkills: ZcodePaths.skillsRoot(),
            antigravitySkills: AntigravityPaths.userSkillsRoot())
    }

    /// Local location of the audit archive (export/audit/dt=YYYY-MM-DD/audit-events-*.parquet)
    static func auditArchiveDir() -> URL {
        EurekaStore.defaultURL().deletingLastPathComponent()
            .appendingPathComponent("export/audit", isDirectory: true)
    }

    /// Fixed location of the eureka analytics snapshot (the export/ subdirectory next to
    /// eureka.sqlite)
    static func eurekaSnapshotURL() -> URL {
        EurekaStore.defaultURL().deletingLastPathComponent()
            .appendingPathComponent("export/eureka-snapshot.sqlite")
    }

    /// Whitelisted Trae roots that may be backed up (skills / user rules × installed channels, plus
    /// the CN-only memory library).
    ///
    /// ⚠️ Only these specific directories are listed. `~/.trae-cn` itself holds `trae-jwt-token` (a JWT) and `mcp.json`
    /// (may contain API keys); `Application Support/Trae CN` holds Cookies and the SQLCipher-encrypted
    /// session DB -- none of them may be included. Built-in skills (`builtin_skills`, `builtin/global/skills`)
    /// ship with the client and are read-only, so there's no value in backing them up either.
    static func traeRoots() -> [(root: URL, category: String)] {
        var result: [(root: URL, category: String)] = []
        for channel in TraePaths.installedChannels() {
            let suffix = channel == .cn ? "" : "-intl"
            result.append((TraePaths.skillsRoot(channel), "trae/skills\(suffix)"))
            result.append((TraePaths.userRulesDir(channel), "trae/rules\(suffix)"))
            // The legacy single-file form coexists with the directory form above → added as a
            // single entry (its parent directory has trae-jwt-token)
            result.append((TraePaths.userRulesFile(channel), "trae/rules\(suffix)"))
        }
        // Only the CN install has a memory library (user_profile.md / projects/**/project_memory.md
        // / topics.md). The markdownOnly filter automatically skips the per-turn
        // session_memory_*.jsonl logs.
        result.append((TraePaths.memoryRoot(), "trae/memory"))
        return result
    }

    /// Materializes Codex / opencode / Grok / Kimi plans into a staging directory (Claude plans are
    /// already .md and need no materializing). Called before syncing so this run can upload the
    /// latest plans.
    static func materializePlans() {
        let staging = PlanMaterializer.defaultStagingRoot()
        PlanMaterializer.materializeCodex(
            sessionsRoot: CodexRolloutTailer.defaultSessionsRoot(), into: staging)
        PlanMaterializer.materializeOpencode(dbPath: OpencodePaths.db(), into: staging)
        PlanMaterializer.materializeGrok(sessionsRoot: GrokPaths.sessionsRoot(), into: staging)
        PlanMaterializer.materializeKimi(sessionsRoot: KimiPaths.sessionsRoot(), into: staging)
        PlanMaterializer.materializeQoder(plansRoot: QoderPaths.plansRoot(), into: staging)
        PlanMaterializer.materializeCursor(into: staging)
    }

    static func describe(_ report: SyncReport) -> String {
        if report.uploaded == 0 && report.failed == 0 && report.deferred == 0 {
            return L10n.text("Already up to date (no changes)", zhHans: "已是最新（无变化）")
        }
        var parts = [L10n.format("Uploaded %@ files", zhHans: "已上传 %@ 个文件", String(report.uploaded))]
        if report.uploadedBytes > 0 {
            parts.append(formatSyncBytes(report.uploadedBytes))
        }
        if report.deferred > 0 {
            parts.append(L10n.format("%@ remaining for the next run", zhHans: "剩 %@ 个下轮继续", String(report.deferred)))
        }
        if report.skippedOversize > 0 {
            parts.append(L10n.format("Skipped %@ oversized files", zhHans: "跳过超大文件 %@ 个", String(report.skippedOversize)))
        }
        return parts.joined(separator: " · ")
    }

    private func publish(_ update: @escaping (SyncService) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            update(self)
        }
    }
}

/// Byte formatting (with GB). **The backup page uses this throughout**: `formatBytes`
/// (SessionsView) stops at MB, so backups over 1 GB would show as "1234.5 MB".
func formatSyncBytes(_ bytes: Int64) -> String {
    switch bytes {
    case ..<1024: return "\(bytes) B"
    case ..<(1 << 20): return String(format: "%.1f KB", Double(bytes) / 1024)
    case ..<(1 << 30): return String(format: "%.1f MB", Double(bytes) / Double(1 << 20))
    default: return String(format: "%.2f GB", Double(bytes) / Double(1 << 30))
    }
}
