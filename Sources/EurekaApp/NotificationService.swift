import EurekaKit
import Foundation
import UserNotifications

/// System notification (UNUserNotificationCenter) wrapper: high-risk audit alerts stay visible on
/// the lock screen / other desktops. Key guard: in a non-.app process (`swift run` dev mode)
/// bundleProxyForCurrentProcess is nil, and touching UNUserNotificationCenter.current() crashes
/// outright -> never call it then; fall back to the in-island red card only.
@MainActor
final class NotificationService: NSObject, ObservableObject {
    enum Availability: Equatable {
        case unknown
        case unavailableNotBundled   // dev mode (swift run): system notifications unavailable
        case authorized
        case denied
    }

    @Published private(set) var availability: Availability =
        NotificationService.isBundled ? .unknown : .unavailableNotBundled

    /// Only a process inside an .app bundle can safely touch UNUserNotificationCenter
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private var center: UNUserNotificationCenter? {
        Self.isBundled ? UNUserNotificationCenter.current() : nil
    }

    /// Called when the system-notification toggle is turned on: requests authorization (the first
    /// time shows the system prompt) and updates availability
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

    /// Refreshes the current authorization status (when the Settings page appears)
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

    /// Posts a high-risk alert (identifier is the opId for dedup, so the same operation isn't
    /// notified twice)
    func postRiskAlert(_ alert: RiskAlert) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.format("⚠️ High-risk operation: %@", zhHans: "⚠️ 高危操作：%@", String(alert.ruleTitle))
        let firstLine = alert.detail.split(separator: "\n", maxSplits: 1).first.map(String.init)
            ?? alert.detail
        content.body = "\(alert.source.displayName) · \(alert.tool)\n\(firstLine)"
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "eureka-audit-\(alert.opId)", content: content, trigger: nil))
    }

    /// Posts a key-event notification (finished / waiting / error; identifier dedups so the same
    /// event doesn't pop twice)
    func postEvent(_ note: SystemEventNotification) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: note.identifier, content: content, trigger: nil))
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Show banner + sound even while the app is frontmost (otherwise foreground notifications are
    /// silenced)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
