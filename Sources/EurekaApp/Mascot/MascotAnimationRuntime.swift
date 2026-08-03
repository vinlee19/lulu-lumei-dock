import AppKit
import EurekaKit
import SwiftUI

/// 管理桌宠逐帧刷新的生命周期。隐藏或系统休眠时暂停，恢复时重建时间轴。
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
