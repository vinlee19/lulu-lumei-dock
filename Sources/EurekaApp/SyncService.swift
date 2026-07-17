import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaSync
import Foundation

/// 云端备份服务：定时（30 分钟）+ 手动触发的增量上传。
/// 所有 IO（钥匙串子进程、文件枚举、网络上传、SQLite）都在私有 utility 队列上；
/// @Published 状态回主线程发布（镜像 UsageService 的模式）。
final class SyncService: ObservableObject {
    @Published private(set) var syncing = false
    @Published private(set) var lastResult: String?
    @Published private(set) var lastError: String?
    @Published private(set) var credentialsConfigured = false
    @Published private(set) var testResult: String?
    /// 同步进行中的实时进度（nil = 空闲）
    @Published private(set) var progress: SyncProgress?
    /// 同步历史当前页（持久化，倒序）与总轮数（分页用）
    @Published private(set) var runs: [SyncRunsRepo.Run] = []
    @Published private(set) var runsTotal = 0
    /// 备份总量统计（sync_state 聚合）
    @Published private(set) var stats: SyncStateRepo.Stats?
    /// 当前同步间隔（分钟，只读展示用）
    @Published private(set) var intervalMinutes: Double = 30

    private let queue = DispatchQueue(label: "com.vinlee.eureka.sync", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// 只在 queue 上访问：skip-if-syncing 守卫
    private var running = false
    /// 每轮开跑时从主线程快照的配置
    private struct Config {
        var provider: StorageProvider
        var region: String
        var bucket: String
        var endpointHost: String  // 仅 provider == .custom 时使用
        var keyPrefix: String

        /// 按服务商预设解析 endpoint host；自定义用用户填写值（空 = 未配置）
        var resolvedEndpointHost: String {
            provider.endpointHost(region: region) ?? endpointHost
        }
    }
    private var config = Config(
        provider: .tencentCOS, region: "", bucket: "", endpointHost: "", keyPrefix: "eureka")

    private static let healthName = "云端备份"
    /// 增量同步间隔（秒），由设置注入（最小 1 分钟），默认 30 分钟
    private var intervalSeconds: TimeInterval = 1800

    // MARK: - 生命周期

    /// 开关打开时启动定时器（首次延迟避开启动扫描高峰，但不超过一个间隔）
    func start() {
        guard timer == nil else { return }
        HealthRegistry.shared.register(Self.healthName, expectedInterval: intervalSeconds)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + min(120, intervalSeconds), repeating: intervalSeconds)
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

    /// 更新同步间隔（分钟，最小 1）；定时器在跑则立即按新间隔重排
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

    /// 刷新备份总量统计（「备份」页签 onAppear + 每轮同步后调用）
    func refreshStats() {
        queue.async { [weak self] in
            guard let self,
                  let store = try? EurekaStore(path: EurekaStore.defaultURL()),
                  let stats = try? store.syncState.stats()
            else { return }
            self.publish { $0.stats = stats }
        }
    }

    /// 同步历史分页加载（page 从 1 起）
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

    /// 配置变更时由 UI 侧调用（每轮开跑读取最新快照）
    func updateConfig(
        provider: StorageProvider, region: String, bucket: String,
        endpointHost: String, keyPrefix: String
    ) {
        queue.async { [weak self] in
            self?.config = Config(
                provider: provider, region: region, bucket: bucket,
                endpointHost: endpointHost, keyPrefix: keyPrefix)
        }
    }

    // MARK: - 动作（全部 queue.async）

    /// 手动「立即同步」：放宽配额，一次尽量传完
    func syncNow() {
        queue.async { [weak self] in
            self?.runCycleIfIdle(limits: .relaxed)
        }
    }

    /// HEAD Bucket 测试连接/凭证
    func testConnection() {
        publish { $0.testResult = "测试中…" }
        queue.async { [weak self] in
            guard let self else { return }
            guard let client = self.makeClient() else {
                self.publish { $0.testResult = "配置不完整：请填写地域、存储桶并保存密钥" }
                return
            }
            do {
                try client.headBucket()
                self.publish { $0.testResult = "连接成功 ✓" }
            } catch {
                self.publish { $0.testResult = "连接失败：\(error)" }
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
                if !ok { $0.lastError = "密钥写入钥匙串失败" }
            }
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    /// 设置页出现时探测钥匙串状态（后台，不阻塞 UI）
    func refreshCredentialStatus() {
        queue.async { [weak self] in
            let configured = KeychainStore.read(account: KeychainStore.secretIdAccount) != nil
                && KeychainStore.read(account: KeychainStore.secretKeyAccount) != nil
            self?.publish { $0.credentialsConfigured = configured }
        }
    }

    // MARK: - 同步循环（queue 上执行）

    private func runCycleIfIdle(limits: SyncEngine.Limits) {
        guard !running else { return }
        running = true
        defer { running = false }
        HealthRegistry.shared.beat(Self.healthName)
        publish { $0.syncing = true; $0.lastError = nil }
        defer { publish { $0.syncing = false } }

        guard let client = makeClient() else {
            publish { $0.lastError = "备份未运行：请填写地域、存储桶并保存密钥" }
            return
        }
        guard let store = try? EurekaStore(path: EurekaStore.defaultURL()) else {
            publish { $0.lastError = "备份失败：本地数据库不可用" }
            HealthRegistry.shared.failure(Self.healthName, note: "sqlite 打开失败")
            return
        }

        Self.materializePlans()  // 物化三源计划到暂存，纳入本轮增量上传

        let engine = SyncEngine(
            client: client, repo: store.syncState, roots: Self.defaultRoots(),
            keyPrefix: config.keyPrefix.isEmpty ? "eureka" : config.keyPrefix,
            host: SyncKeyMapper.deviceNamespace(), limits: limits)
        engine.onProgress = { [weak self] snapshot in
            self?.publish { $0.progress = snapshot }
        }
        let report = engine.runCycle()
        publish { $0.progress = nil }

        if report.uploaded > 0 {
            HealthRegistry.shared.event(Self.healthName)
        }
        if let error = report.firstError {
            HealthRegistry.shared.failure(Self.healthName, note: error)
        }
        // 有实质动作才记一轮（跳过无变化的空轮），持久化后修剪
        if report.uploaded > 0 || report.failed > 0 {
            try? store.syncRuns.insert(
                date: Date(), uploaded: report.uploaded, uploadedBytes: report.uploadedBytes,
                failed: report.failed, deferred: report.deferred, error: report.firstError,
                files: report.uploadedFiles.map {
                    SyncRunsRepo.RunFile(name: $0.name, size: $0.size)
                })
            try? store.syncRuns.prune(keepingLast: 200)
        }
        publish {
            $0.lastResult = Self.describe(report)
            $0.lastError = report.firstError.map { "部分失败（\(report.failed) 个）：\($0)" }
        }
        loadRuns(page: 1)
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
            claudePlans: PlanMaterializer.defaultClaudePlansDir(),
            plansStaging: PlanMaterializer.defaultStagingRoot())
    }

    /// 物化 Codex / opencode 计划到暂存目录（Claude 计划本就是 .md，无需物化）。
    /// 在同步前调用，让本轮就能上传最新计划。
    static func materializePlans() {
        let staging = PlanMaterializer.defaultStagingRoot()
        PlanMaterializer.materializeCodex(
            sessionsRoot: CodexRolloutTailer.defaultSessionsRoot(), into: staging)
        PlanMaterializer.materializeOpencode(dbPath: OpencodePaths.db(), into: staging)
        PlanMaterializer.materializeGrok(sessionsRoot: GrokPaths.sessionsRoot(), into: staging)
        PlanMaterializer.materializeKimi(sessionsRoot: KimiPaths.sessionsRoot(), into: staging)
    }

    static func describe(_ report: SyncReport) -> String {
        if report.uploaded == 0 && report.failed == 0 && report.deferred == 0 {
            return "已是最新（无变化）"
        }
        var parts = ["已上传 \(report.uploaded) 个文件"]
        if report.uploadedBytes > 0 {
            parts.append(formatSyncBytes(report.uploadedBytes))
        }
        if report.deferred > 0 {
            parts.append("剩 \(report.deferred) 个下轮继续")
        }
        if report.skippedOversize > 0 {
            parts.append("跳过超大文件 \(report.skippedOversize) 个")
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

private func formatSyncBytes(_ bytes: Int64) -> String {
    switch bytes {
    case ..<1024: return "\(bytes) B"
    case ..<(1 << 20): return String(format: "%.1f KB", Double(bytes) / 1024)
    case ..<(1 << 30): return String(format: "%.1f MB", Double(bytes) / Double(1 << 20))
    default: return String(format: "%.2f GB", Double(bytes) / Double(1 << 30))
    }
}
