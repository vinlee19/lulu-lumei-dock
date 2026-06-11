import Foundation
import ServiceManagement

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
    /// 健康提示（连续过久/会话过多/深夜关怀）
    @Published var wellnessEnabled: Bool {
        didSet { defaults.set(wellnessEnabled, forKey: "wellnessEnabled") }
    }
    /// 连续活跃多少小时后提醒
    @Published var wellnessThresholdHours: Double {
        didSet { defaults.set(wellnessThresholdHours, forKey: "wellnessThresholdHours") }
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
        wellnessEnabled = defaults.object(forKey: "wellnessEnabled") as? Bool ?? true
        wellnessThresholdHours = defaults.object(forKey: "wellnessThresholdHours") as? Double ?? 2
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
