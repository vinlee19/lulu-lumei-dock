import AppKit
import EurekaKit

/// Builds the main menu programmatically (SwiftPM has no XIB). A regular app needs it to provide
/// standard actions such as About / Hide / Quit and Window (Minimize / Zoom / Full Screen / Close).
enum MainMenu {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: L10n.text("About lulu-lumei-dock", zhHans: "关于 lulu-lumei-dock"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L10n.text("Hide lulu-lumei-dock", zhHans: "隐藏 lulu-lumei-dock"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        let hideOthers = NSMenuItem(
            title: L10n.text("Hide Others", zhHans: "隐藏其他"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(
            withTitle: L10n.text("Show All", zhHans: "显示全部"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L10n.text("Quit lulu-lumei-dock", zhHans: "退出 lulu-lumei-dock"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        // Find menu: ⌘K global search (the action is forwarded to the SwiftUI layer via a
        // notification; a menu can't reach view state directly)
        let findItem = NSMenuItem()
        mainMenu.addItem(findItem)
        let findMenu = NSMenu(title: L10n.text("Find", zhHans: "查找"))
        findItem.submenu = findMenu
        let paletteItem = NSMenuItem(
            title: L10n.text("Search Everywhere…", zhHans: "全局搜索…"),
            action: #selector(MenuActions.togglePalette(_:)),
            keyEquivalent: "k")
        paletteItem.target = MenuActions.shared
        findMenu.addItem(paletteItem)

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: L10n.text("Window", zhHans: "窗口"))
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: L10n.text("Minimize", zhHans: "最小化"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: L10n.text("Zoom", zhHans: "缩放"),
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: "")
        windowMenu.addItem(.separator())
        let fullScreen = NSMenuItem(
            title: L10n.text("Enter Full Screen", zhHans: "进入全屏幕"),
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(fullScreen)
        windowMenu.addItem(
            withTitle: L10n.text("Close", zhHans: "关闭"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }
}

/// NSObject landing point for menu actions (menu items need a target/selector).
final class MenuActions: NSObject {
    static let shared = MenuActions()

    /// Don't post the notification directly: while the main window is hidden, PopoverRootView's
    /// onReceive still gets it and silently flips paletteVisible. The user can't see the window, so
    /// they can't see the flip either, and the next time the window shows the palette's open state
    /// won't match what they expect. Going through AppDelegate brings the main window forward
    /// first, then posts, so the flip happens where the user can see it. Menu actions must be
    /// synchronous @objc methods (no await); AppKit guarantees they run on the main thread, so
    /// assumeIsolated steps past AppDelegate's @MainActor isolation.
    @objc func togglePalette(_ sender: Any?) {
        MainActor.assumeIsolated {
            (NSApp.delegate as? AppDelegate)?.showPalette()
        }
    }
}
