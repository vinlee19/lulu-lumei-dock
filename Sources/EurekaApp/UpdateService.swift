import Combine
import Foundation
import Sparkle

/// Sparkle in-app update entry point. Enabled only for a standard .app bundle; `swift run` and all
/// CLI modes never check over the network.
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

    /// Starts the scheduler and, per the user's current preference, runs one extra background "this
    /// launch" check. Sparkle requires a forced launch check to be called right after the updater
    /// starts.
    func start() {
        guard !hasStarted, let updaterController else { return }
        hasStarted = true
        updaterController.startUpdater()
        if updaterController.updater.automaticallyChecksForUpdates {
            updaterController.updater.checkForUpdatesInBackground()
        }
    }

    /// Sparkle writes this property to NSUserDefaults itself; don't store another copy in
    /// AppSettings.
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater = updaterController?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
    }

    /// User-initiated standard Sparkle flow; both "no update" and network errors get explicit
    /// feedback from the standard UI.
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
