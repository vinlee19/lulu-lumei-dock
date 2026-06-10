import AppKit

// CLI 模式（hooks 装卸/状态查询）直接处理后退出，不起 GUI
if EurekaCLI.runIfNeeded() {
    exit(0)
}

// 菜单栏应用入口：无 Dock 图标（accessory），生命周期交给 AppDelegate。
// 打包后由 Info.plist 的 LSUIElement 兜底；swift run 直跑时靠 setActivationPolicy。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
