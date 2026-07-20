import Combine
import Foundation
import Sparkle

/// Sparkle 应用内更新入口。仅标准 .app 包启用；`swift run` 与所有 CLI 模式都不会联网检查。
@MainActor
final class UpdateService: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var isAvailable = false

    private let updaterController: SPUStandardUpdaterController?
    private var hasStarted = false
    private var cancellables: Set<AnyCancellable> = []

    init(bundle: Bundle = .main) {
        guard Self.isStandardApplicationBundle(bundle) else {
            updaterController = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil)
        updaterController = controller
        isAvailable = true
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
            .store(in: &cancellables)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.automaticallyChecksForUpdates = value }
            .store(in: &cancellables)
    }

    /// 启动调度器，并按用户当前偏好额外执行一次“本次启动”的后台检查。
    /// Sparkle 要求强制启动检查只能紧跟在 updater 启动之后调用。
    func start() {
        guard !hasStarted, let updaterController else { return }
        hasStarted = true
        updaterController.startUpdater()
        if updaterController.updater.automaticallyChecksForUpdates {
            updaterController.updater.checkForUpdatesInBackground()
        }
    }

    /// 此属性由 Sparkle 自己写入 NSUserDefaults；不要在 AppSettings 中再存一份。
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater = updaterController?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
    }

    /// 用户主动触发标准 Sparkle 流程；无更新与网络错误均由标准界面明确反馈。
    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updaterController?.checkForUpdates(nil)
    }

    private static func isStandardApplicationBundle(_ bundle: Bundle) -> Bool {
        guard bundle.bundleURL.pathExtension == "app",
              let executableURL = bundle.executableURL,
              bundle.object(forInfoDictionaryKey: "SUFeedURL") is String else {
            return false
        }
        let macOSDirectory = bundle.bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .standardizedFileURL.path + "/"
        return executableURL.standardizedFileURL.path.hasPrefix(macOSDirectory)
    }
}
