import EurekaKit
import Foundation
import UserNotifications

/// 系统通知（UNUserNotificationCenter）封装：高危审计告警在锁屏/其他桌面也可见。
/// 关键守卫：非 .app 进程（swift run 开发态）下 bundleProxyForCurrentProcess 为 nil，
/// 一旦触碰 UNUserNotificationCenter.current() 会直接崩溃 → 此时完全不调用，降级为仅岛内红卡。
@MainActor
final class NotificationService: NSObject, ObservableObject {
    enum Availability: Equatable {
        case unknown
        case unavailableNotBundled   // 开发态（swift run）：系统通知不可用
        case authorized
        case denied
    }

    @Published private(set) var availability: Availability =
        NotificationService.isBundled ? .unknown : .unavailableNotBundled

    /// 只有 .app 包内进程才能安全触碰 UNUserNotificationCenter
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private var center: UNUserNotificationCenter? {
        Self.isBundled ? UNUserNotificationCenter.current() : nil
    }

    /// 打开系统通知开关时调用：请求授权（首次弹系统弹窗），更新 availability
    func enable() {
        guard let center else {
            availability = .unavailableNotBundled
            return
        }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.availability = granted ? .authorized : .denied
            }
        }
    }

    /// 刷新当前授权状态（设置页出现时）
    func refresh() {
        guard let center else {
            availability = .unavailableNotBundled
            return
        }
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: self?.availability = .authorized
                case .denied: self?.availability = .denied
                default: self?.availability = .unknown
                }
            }
        }
    }

    /// 推送一条高危告警（identifier 用 opId 去重，避免同操作重复通知）
    func postRiskAlert(_ alert: RiskAlert) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "⚠️ 高危操作：\(alert.ruleTitle)"
        let firstLine = alert.detail.split(separator: "\n", maxSplits: 1).first.map(String.init)
            ?? alert.detail
        content.body = "\(alert.source.displayName) · \(alert.tool)\n\(firstLine)"
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "eureka-audit-\(alert.opId)", content: content, trigger: nil))
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    /// app 前台时也横幅 + 声音展示（否则前台通知会被静默）
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
