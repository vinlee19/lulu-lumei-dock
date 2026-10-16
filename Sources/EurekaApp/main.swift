import AppKit
import EurekaKit

// CLI 模式（hooks 装卸/状态查询）直接处理后退出，不起 GUI。
// 语言偏好要在 CLI 打出任何文案之前装上；没有存过偏好时是英文。
L10n.applyStoredPreference()
if EurekaCLI.runIfNeeded() {
    exit(0)
}

// 常规应用入口：有 Dock 图标 + 应用菜单 + 主窗口（生命周期交给 AppDelegate）。
// swift run 直跑时这里是激活策略的唯一来源，运行期也压过 Info.plist。
// 顶层代码不是静态 MainActor 上下文，但主线程事实成立 → assumeIsolated。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
