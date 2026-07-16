import AppKit
import Combine
import EurekaKit

/// 菜单栏：左键前置主窗口，右键菜单（退出）；
/// 标题 = 任务计数 + 限额百分比（取双源 5h 窗口最大值，60%/85% 变色）
@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private let usageService: UsageService
    private let limitsService: RateLimitsService
    private let settings: AppSettings
    /// 左键回调：前置/激活主窗口（由 AppDelegate 接到 MainWindowController.show）
    private let onActivate: () -> Void
    private var lastTasks: [AgentTask] = []
    private var cancellables: Set<AnyCancellable> = []

    init(
        usageService: UsageService,
        limitsService: RateLimitsService,
        settings: AppSettings,
        onActivate: @escaping () -> Void
    ) {
        self.usageService = usageService
        self.limitsService = limitsService
        self.settings = settings
        self.onActivate = onActivate
        super.init()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "✦"
        item.button?.toolTip = "lulu-lumei-dock"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        // 限额变化 / 开关变化 → 重组标题（任务变化走 update(tasks:)）
        limitsService.$codex
            .combineLatest(
                limitsService.$grok, limitsService.$claude, settings.$menuBarShowsLimit)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in
                MainActor.assumeIsolated { self?.renderTitle() }
            }
            .store(in: &cancellables)
        renderTitle()
    }

    /// 状态栏文字随活跃任务变化
    func update(tasks: [AgentTask]) {
        lastTasks = tasks
        renderTitle()
    }

    private func renderTitle() {
        guard let button = statusItem?.button else { return }
        let waiting = lastTasks.contains {
            if case .waiting = $0.phase { return true } else { return false }
        }
        let title = StatusTitleComposer.compose(
            taskCount: lastTasks.count,
            hasWaiting: waiting,
            maxUsedPercent: StatusTitleComposer.maxPrimaryPercent(
                [limitsService.codex, limitsService.grok, limitsService.claude]),
            showLimit: settings.menuBarShowsLimit
        )

        if let percent = title.percent, title.tier != .normal {
            // 百分比部分按档位着色
            let font = button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let attributed = NSMutableAttributedString(
                string: title.base + " · ", attributes: [.font: font])
            let color: NSColor = title.tier == .critical ? .systemRed : .systemOrange
            attributed.append(NSAttributedString(
                string: percent,
                attributes: [.font: font, .foregroundColor: color]))
            button.attributedTitle = attributed
        } else {
            button.title = title.combined
        }
        button.toolTip = limitsTooltip()
    }

    private func limitsTooltip() -> String {
        var parts: [String] = []
        for snapshot in [limitsService.codex, limitsService.grok, limitsService.claude] {
            guard let snapshot, let primary = snapshot.primary else { continue }
            var text = "\(snapshot.source.displayName) \(Int(primary.usedPercent.rounded()))%"
            if let secondary = snapshot.secondary {
                text += "（周 \(Int(secondary.usedPercent.rounded()))%）"
            }
            parts.append(text)
        }
        return parts.isEmpty ? "lulu-lumei-dock" : parts.joined(separator: " · ")
    }

    @objc private func statusItemClicked() {
        MainActor.assumeIsolated {
            if NSApp.currentEvent?.type == .rightMouseUp {
                showMenu()
                return
            }
            onActivate()
        }
    }

    private func showMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "打开主窗口",
            action: #selector(openMainWindow),
            keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "退出 lulu-lumei-dock",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil  // 用完即拆，避免左键也弹菜单
    }

    @objc private func openMainWindow() {
        MainActor.assumeIsolated { onActivate() }
    }
}
