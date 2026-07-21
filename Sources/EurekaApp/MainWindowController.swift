import AppKit
import SwiftUI

/// 主应用窗口：承载 PopoverRootView 的侧边栏导航，做成可缩放/可全屏的标准窗口。
/// 与菜单栏共享同一批服务实例（由 AppDelegate 注入），状态实时一致。
@MainActor
final class MainWindowController: NSWindowController {
    private let usageService: UsageService
    private let limitsService: RateLimitsService
    private let navigation: PopoverNavigation

    init(
        usageService: UsageService,
        limitsService: RateLimitsService,
        settings: AppSettings,
        installer: InstallerService,
        sessionBrowser: SessionBrowserService,
        skillMemoryService: SkillMemoryService,
        plansService: PlansService,
        agentConfigService: AgentConfigService,
        syncService: SyncService,
        cliToolsService: CLIToolsService,
        auditService: AuditService,
        notificationService: NotificationService,
        updateService: UpdateService,
        navigation: PopoverNavigation
    ) {
        self.usageService = usageService
        self.limitsService = limitsService
        self.navigation = navigation

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "lulu-lumei-dock"
        window.minSize = NSSize(width: 840, height: 540)
        window.collectionBehavior.insert(.fullScreenPrimary)
        // 关窗后不释放：菜单栏/Dock 点击可重新打开同一个窗口（否则 use-after-free）
        window.isReleasedWhenClosed = false

        let hosting = NSHostingController(
            rootView: PopoverRootView(
                usageService: usageService,
                limitsService: limitsService,
                settings: settings,
                installer: installer,
                sessionBrowser: sessionBrowser,
                skillMemoryService: skillMemoryService,
                plansService: plansService,
                agentConfigService: agentConfigService,
                syncService: syncService,
                cliToolsService: cliToolsService,
                auditService: auditService,
                notificationService: notificationService,
                updateService: updateService,
                navigation: navigation))
        // 不让 SwiftUI 理想尺寸反向重设窗口 frame（否则首开被压到最小宽高、内容挤压重叠）
        hosting.sizingOptions = []
        window.contentViewController = hosting
        // contentViewController 赋值会把窗口缩到内容 fitting 尺寸，这里再钉回默认尺寸
        window.setContentSize(NSSize(width: 900, height: 620))
        window.setFrameAutosaveName("EurekaMainWindow")
        // 有已存 frame 则恢复，否则居中首开
        if !window.setFrameUsingName("EurekaMainWindow") {
            window.center()
        } else if window.frame.width < 840 || window.frame.height < 540 {
            // 旧版本曾把被 SwiftUI 压缩的小窗存进 autosave；恢复时钳回最小尺寸
            var frame = window.frame
            frame.size.width = max(frame.size.width, 840)
            frame.size.height = max(frame.size.height, 540)
            window.setFrame(frame, display: false)
        }

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    /// 显示/前置主窗口（可选切到指定页签）。激活顺序：先 activate 再 makeKey，
    /// 否则窗口可能藏在其他应用之后。
    func show(tab: PopoverRootView.Tab? = nil) {
        if let tab { navigation.tab = tab }
        usageService.refreshNow()
        limitsService.refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
