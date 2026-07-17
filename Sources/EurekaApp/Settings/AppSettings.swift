import Foundation
import ServiceManagement

/// 用户自定义同步目录（备份自选目录 → 远端 `custom/<名>`）
struct CustomSyncFolder: Codable, Equatable, Identifiable {
    var id = UUID()
    var path: String
    var remoteName: String
    var enabled = true

    /// 远端类目：`custom/<清洗后的远端名>`（去斜杠与首尾空白；空名回退文件夹名）
    var remoteCategory: String {
        let cleaned = remoteName
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = URL(fileURLWithPath: path).lastPathComponent
        return "custom/" + (cleaned.isEmpty ? fallback : cleaned)
    }
}

/// 用户偏好（UserDefaults 持久化）
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
    @Published var autoDismissSeconds: Double {
        didSet { defaults.set(autoDismissSeconds, forKey: "autoDismissSeconds") }
    }
    /// 岛上时间显示：false=已持续时长，true=开始的日期时间
    @Published var showStartTime: Bool {
        didSet { defaults.set(showStartTime, forKey: "islandShowStartTime") }
    }
    /// 菜单栏标题显示限额百分比
    @Published var menuBarShowsLimit: Bool {
        didSet { defaults.set(menuBarShowsLimit, forKey: "menuBarShowsLimit") }
    }
    /// 健康提示（连续过久/会话过多/深夜关怀）
    @Published var wellnessEnabled: Bool {
        didSet { defaults.set(wellnessEnabled, forKey: "wellnessEnabled") }
    }
    /// 连续活跃多少小时后提醒
    @Published var wellnessThresholdHours: Double {
        didSet { defaults.set(wellnessThresholdHours, forKey: "wellnessThresholdHours") }
    }
    /// 会话面板按时间最多展示多少个会话（0 = 全部）
    @Published var sessionDisplayLimit: Int {
        didSet { defaults.set(sessionDisplayLimit, forKey: "sessionDisplayLimit") }
    }
    /// 历史列表排序：active=最近活跃 / start=最初对话开始时间（存 rawValue）
    @Published var historySortMode: String {
        didSet { defaults.set(historySortMode, forKey: "historySortMode") }
    }
    /// 会话列表排序：time=最近活跃 / size=按大小 / duration=按时长（存 rawValue）
    @Published var sessionSortMode: String {
        didSet { defaults.set(sessionSortMode, forKey: "sessionSortMode") }
    }
    /// 外观主题：system=跟随系统 / light=浅色 / dark=深色
    @Published var appearanceMode: String {
        didSet { defaults.set(appearanceMode, forKey: "appearanceMode") }
    }
    /// 桌面吉祥物（默认关，opt-in）
    @Published var mascotEnabled: Bool {
        didSet { defaults.set(mascotEnabled, forKey: "mascotEnabled") }
    }
    /// 当前吉祥物动画包 id（"built-in" 或 mascots/ 下目录名）
    @Published var mascotPack: String {
        didSet { defaults.set(mascotPack, forKey: "mascotPack") }
    }
    /// 云端备份（默认关，opt-in；密钥存钥匙串、不进 UserDefaults）
    @Published var cloudBackupEnabled: Bool {
        didSet { defaults.set(cloudBackupEnabled, forKey: "cloudBackupEnabled") }
    }
    /// 存储服务商（StorageProvider rawValue）
    @Published var storageProvider: String {
        didSet { defaults.set(storageProvider, forKey: "storageProvider") }
    }
    /// COS 地域（如 ap-guangzhou）
    @Published var cosRegion: String {
        didSet { defaults.set(cosRegion, forKey: "cosRegion") }
    }
    /// COS 存储桶（如 backup-1250000000）
    @Published var cosBucket: String {
        didSet { defaults.set(cosBucket, forKey: "cosBucket") }
    }
    /// 自定义 endpoint host（空 = COS 默认；AWS 填 s3.<region>.amazonaws.com）
    @Published var cosEndpointHost: String {
        didSet { defaults.set(cosEndpointHost, forKey: "cosEndpointHost") }
    }
    /// 对象键前缀
    @Published var cosKeyPrefix: String {
        didSet { defaults.set(cosKeyPrefix, forKey: "cosKeyPrefix") }
    }
    /// 增量同步间隔（分钟，最小 1）
    @Published var cosSyncIntervalMinutes: Double {
        didSet { defaults.set(cosSyncIntervalMinutes, forKey: "cosSyncIntervalMinutes") }
    }
    /// 备份单文件失败重试次数（0 = 关；仅网络错误/5xx 重试）
    @Published var cosRetryAttempts: Int {
        didSet { defaults.set(cosRetryAttempts, forKey: "cosRetryAttempts") }
    }
    /// 重试退避基数（秒，指数 ×2）
    @Published var cosRetryBackoffSeconds: Double {
        didSet { defaults.set(cosRetryBackoffSeconds, forKey: "cosRetryBackoffSeconds") }
    }
    /// 自定义同步目录（JSON 编码存 UserDefaults——本仓库首个数组型设置）
    @Published var customSyncFolders: [CustomSyncFolder] {
        didSet {
            if let data = try? JSONEncoder().encode(customSyncFolders) {
                defaults.set(data, forKey: "customSyncFolders")
            }
        }
    }
    /// 安全审计：记录 agent 执行的操作（命令全文/文件路径，不含输出）。默认开。
    @Published var auditEnabled: Bool {
        didSet { defaults.set(auditEnabled, forKey: "auditEnabled") }
    }
    /// 高危操作岛内红卡告警。默认开。
    @Published var auditRiskAlertsEnabled: Bool {
        didSet { defaults.set(auditRiskAlertsEnabled, forKey: "auditRiskAlertsEnabled") }
    }
    /// 高危操作系统通知（锁屏/其他 Space 可见）。默认关，opt-in，开启时才请求授权。
    @Published var auditSystemNotifyEnabled: Bool {
        didSet { defaults.set(auditSystemNotifyEnabled, forKey: "auditSystemNotifyEnabled") }
    }
    /// 审计流水保留天数（0 = 永久）。默认 90。
    @Published var auditRetentionDays: Int {
        didSet { defaults.set(auditRetentionDays, forKey: "auditRetentionDays") }
    }
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginHint: String?

    private let defaults = UserDefaults.standard

    init() {
        notifyCompletion = defaults.object(forKey: "notifyCompletion") as? Bool ?? true
        notifyWaiting = defaults.object(forKey: "notifyWaiting") as? Bool ?? true
        notifyError = defaults.object(forKey: "notifyError") as? Bool ?? true
        autoDismissSeconds = defaults.object(forKey: "autoDismissSeconds") as? Double ?? 6
        showStartTime = defaults.bool(forKey: "islandShowStartTime")
        menuBarShowsLimit = defaults.object(forKey: "menuBarShowsLimit") as? Bool ?? true
        wellnessEnabled = defaults.object(forKey: "wellnessEnabled") as? Bool ?? true
        wellnessThresholdHours = defaults.object(forKey: "wellnessThresholdHours") as? Double ?? 2
        sessionDisplayLimit = defaults.object(forKey: "sessionDisplayLimit") as? Int ?? 10
        historySortMode = defaults.string(forKey: "historySortMode") ?? "active"
        sessionSortMode = defaults.string(forKey: "sessionSortMode") ?? "time"
        appearanceMode = defaults.string(forKey: "appearanceMode") ?? "system"
        mascotEnabled = defaults.bool(forKey: "mascotEnabled")
        mascotPack = defaults.string(forKey: "mascotPack") ?? "built-in"
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
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// SMAppService 对 ad-hoc/开发态注册可能不稳：失败给降级提示而不是静默
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
            launchAtLoginHint = "注册失败（\(error.localizedDescription)）。"
                + "请先 make install 安装到 ~/Applications 后再开启，"
                + "或在 系统设置 > 通用 > 登录项 手动添加。"
        }
    }
}
