import AppKit
import EurekaKit
import SwiftUI

/// 菜单栏：左键开 popover（历史/用量），右键菜单（退出）
@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let usageService: UsageService
    private let limitsService: RateLimitsService
    private let sessionBrowser = SessionBrowserService()
    private let navigation = PopoverNavigation()

    init(
        usageService: UsageService,
        limitsService: RateLimitsService,
        settings: AppSettings,
        installer: InstallerService
    ) {
        self.usageService = usageService
        self.limitsService = limitsService
        super.init()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 460)
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView(
                usageService: usageService,
                limitsService: limitsService,
                settings: settings,
                installer: installer,
                sessionBrowser: sessionBrowser,
                navigation: navigation))

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "✦"
        item.button?.toolTip = "Eureka"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    /// 状态栏文字随活跃任务变化
    func update(tasks: [AgentTask]) {
        let waiting = tasks.contains {
            if case .waiting = $0.phase { return true } else { return false }
        }
        let title: String
        if tasks.isEmpty {
            title = "✦"
        } else if waiting {
            title = "⏳\(tasks.count)"
        } else {
            title = "▶\(tasks.count)"
        }
        statusItem?.button?.title = title
    }

    /// 程序化打开 popover（首启引导直达设置页）
    func showPopover(tab: PopoverRootView.Tab) {
        navigation.tab = tab
        guard let button = statusItem?.button, !popover.isShown else { return }
        usageService.refreshNow()
        limitsService.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func statusItemClicked() {
        MainActor.assumeIsolated {
            guard let button = statusItem?.button else { return }
            if NSApp.currentEvent?.type == .rightMouseUp {
                showMenu()
                return
            }
            if popover.isShown {
                popover.performClose(nil)
            } else {
                usageService.refreshNow()
                limitsService.refresh()
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    private func showMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "退出 Eureka",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil  // 用完即拆，避免左键也弹菜单
    }
}
