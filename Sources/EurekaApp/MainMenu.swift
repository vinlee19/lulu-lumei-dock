import AppKit

/// 程序化构建主菜单（SwiftPM 无 XIB）。常规应用需要它来提供
/// 关于/隐藏/退出 与 窗口（最小化/缩放/全屏/关闭）等标准动作。
enum MainMenu {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()

        // App 菜单
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "关于 lulu-lumei-dock",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "隐藏 lulu-lumei-dock",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        let hideOthers = NSMenuItem(
            title: "隐藏其他",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(
            withTitle: "显示全部",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 lulu-lumei-dock",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        // 查找菜单：⌘K 全局搜索（动作经通知转发给 SwiftUI 层——菜单无法直接触达视图状态）
        let findItem = NSMenuItem()
        mainMenu.addItem(findItem)
        let findMenu = NSMenu(title: "查找")
        findItem.submenu = findMenu
        let paletteItem = NSMenuItem(
            title: "全局搜索…",
            action: #selector(MenuActions.togglePalette(_:)),
            keyEquivalent: "k")
        paletteItem.target = MenuActions.shared
        findMenu.addItem(paletteItem)

        // 窗口菜单
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "最小化",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: "缩放",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: "")
        windowMenu.addItem(.separator())
        let fullScreen = NSMenuItem(
            title: "进入全屏幕",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(fullScreen)
        windowMenu.addItem(
            withTitle: "关闭",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }
}

/// 菜单动作的 NSObject 落点（菜单项必须有 target/selector；只做通知转发）
final class MenuActions: NSObject {
    static let shared = MenuActions()

    @objc func togglePalette(_ sender: Any?) {
        NotificationCenter.default.post(name: .eurekaToggleCommandPalette, object: nil)
    }
}
