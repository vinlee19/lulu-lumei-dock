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

        // 默认尺寸：屏幕可见区域的 75%，上限 1440×900、下限 840×540（= minSize）
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let defaultSize = NSSize(
            width: min(max(visible.width * 0.75, 840), 1440),
            height: min(max(visible.height * 0.75, 540), 900))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
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
        window.setContentSize(defaultSize)
        // key 带 2：v0.1.8 前的 shrink-bug 会把压缩后的小窗存进旧 key，换名一次性抛弃脏数据
        window.setFrameAutosaveName("EurekaMainWindow2")
        // 有已存 frame 则恢复，否则居中首开
        if !window.setFrameUsingName("EurekaMainWindow2") {
            window.center()
        } else if window.frame.width < 840 || window.frame.height < 540 {
            // 恢复到低于最小尺寸的 frame 时钳回（防外部写入的异常值）
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
