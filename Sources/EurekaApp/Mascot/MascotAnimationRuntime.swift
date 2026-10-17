import AppKit
import EurekaKit
import SwiftUI

/// Manages the lifecycle of the mascot's per-frame refresh. Pauses while hidden or when the system
/// sleeps, and rebuilds the timeline on resume.
@MainActor
final class MascotAnimationRuntime: ObservableObject {
    @Published private(set) var isVisible = false
    @Published private(set) var isAwake = true
    @Published private(set) var epoch = 0

    var animationsActive: Bool {
        MascotAnimationPolicy.shouldAnimate(isVisible: isVisible, isAwake: isAwake)
    }

    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAwake(false) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAwake(true) }
            })
        }
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if visible { epoch &+= 1 }
    }

    private func setAwake(_ awake: Bool) {
        guard isAwake != awake else { return }
        isAwake = awake
        if awake { epoch &+= 1 }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }
}
