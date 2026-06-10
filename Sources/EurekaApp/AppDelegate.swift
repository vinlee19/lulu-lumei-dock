import AppKit
import EurekaKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "✦"
        item.button?.toolTip = "Eureka"
        statusItem = item
        // M1：启动 SpoolConsumer → TaskStore → 状态栏计数
    }
}
