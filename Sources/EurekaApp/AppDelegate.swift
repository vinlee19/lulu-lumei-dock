import AppKit
import Combine
import EurekaIngest
import EurekaKit
import EurekaSync

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var mainWindow: MainWindowController?
    private let store = TaskStore()
    private let usageService = UsageService()
    private let limitsService = RateLimitsService()
    private let settings = AppSettings()
    private let installer = InstallerService()
    // 主窗口与菜单栏共享的服务实例（所有权在此，注入两处保证状态一致）
    private let sessionBrowser = SessionBrowserService()
    private let skillMemory = SkillMemoryService()
    private let plans = PlansService()
    private let agentConfig = AgentConfigService()
    private let syncService = SyncService()
    private let cliTools = CLIToolsService()
    private let auditService = AuditService()
    private let notificationService = NotificationService()
    private let updateService = UpdateService()
    private let navigation = PopoverNavigation()
    private var pipeline: EventPipeline?
    private var reapTimer: Timer?
    private var islandController: IslandPanelController?
    private var mascotController: MascotPanelController?
    private var wellnessMonitor: WellnessMonitor?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 每次启动把随包 relay 同步到稳定路径（升级 app 后 hooks 不断链）
        RelaySyncer.sync()
        // 模型上下文窗口覆盖表（ctx% 的分母；启动时一次性加载）
        ContextWindows.loadOverrides(
            from: SpoolPaths.root().appendingPathComponent("context-windows.json"))

        // 常规应用主菜单（关于/隐藏/退出 + 窗口）
        NSApp.mainMenu = MainMenu.build()

        // 仅正式 .app 启用；启动后按 Sparkle 自带偏好立即执行一次后台检查。
        updateService.start()

        // 主窗口：复用 PopoverRootView 的 6 个页签，与菜单栏共享服务
        let window = MainWindowController(
            usageService: usageService, limitsService: limitsService,
            settings: settings, installer: installer,
            sessionBrowser: sessionBrowser, skillMemoryService: skillMemory,
            plansService: plans,
            agentConfigService: agentConfig, syncService: syncService,
            cliToolsService: cliTools, auditService: auditService,
            notificationService: notificationService, updateService: updateService,
            navigation: navigation)
        mainWindow = window

        statusController = StatusItemController(
            usageService: usageService, limitsService: limitsService,
            settings: settings,
            onActivate: { [weak self] in self?.mainWindow?.show() })
        let island = IslandPanelController()
        island.start()
        islandController = island

        // 桌面吉祥物（默认关，opt-in；与灵动岛并存）
        let mascot = MascotPanelController()
        mascot.onRequestHide = { [weak self] in self?.settings.mascotEnabled = false }
        mascot.onOpenSettings = { [weak self] in self?.mainWindow?.show(tab: .settings) }
        mascot.applyPack(id: settings.mascotPack)
        mascot.start()
        mascotController = mascot
        settings.$mascotEnabled
            .sink { [weak mascot] on in mascot?.setVisible(on) }
            .store(in: &cancellables)
        settings.$mascotPack
            .sink { [weak mascot] id in mascot?.applyPack(id: id) }
            .store(in: &cancellables)

        // 外观主题：启动应用 + 跟随设置变更
        Self.applyAppearance(settings.appearanceMode)
        settings.$appearanceMode
            .dropFirst()
            .sink { mode in Self.applyAppearance(mode) }
            .store(in: &cancellables)

        usageService.start()
        limitsService.start()

        // 安全审计：Codex 定时扫描 + Claude 旁路事件；高危命中 → 岛红卡 + 系统通知（各受开关门控）
        auditService.onRiskAlert = { [weak self] alert in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.logLine("审计告警 \(alert.ruleId) [\(alert.source.rawValue)] \(alert.tool): \(alert.detail)")
                if self.settings.auditRiskAlertsEnabled {
                    self.islandController?.viewModel.enqueueAlert(alert)
                }
                if self.settings.auditSystemNotifyEnabled {
                    self.notificationService.postRiskAlert(alert)
                }
            }
        }
        auditService.setCaptureEnabled(settings.auditEnabled)
        auditService.updateRetention(days: settings.auditRetentionDays)
        auditService.start()
        settings.$auditEnabled
            .sink { [weak auditService] on in auditService?.setCaptureEnabled(on) }
            .store(in: &cancellables)
        settings.$auditRetentionDays
            .sink { [weak auditService] days in auditService?.updateRetention(days: days) }
            .store(in: &cancellables)
        // 系统通知授权：开启开关时请求（非 .app 开发态自动降级为仅岛内红卡）
        if settings.auditSystemNotifyEnabled { notificationService.enable() }
        settings.$auditSystemNotifyEnabled
            .dropFirst()
            .sink { [weak notificationService] on in if on { notificationService?.enable() } }
            .store(in: &cancellables)

        // 云端备份：配置快照推送 + 开关驱动定时器
        let pushSyncConfig = { [weak self] in
            guard let self else { return }
            self.syncService.updateConfig(
                provider: StorageProvider(rawValue: self.settings.storageProvider) ?? .tencentCOS,
                region: self.settings.cosRegion, bucket: self.settings.cosBucket,
                endpointHost: self.settings.cosEndpointHost,
                keyPrefix: self.settings.cosKeyPrefix,
                retryAttempts: self.settings.cosRetryAttempts,
                retryBackoffSeconds: self.settings.cosRetryBackoffSeconds,
                customFolders: self.settings.customSyncFolders)
        }
        pushSyncConfig()
        settings.$storageProvider.sink { _ in pushSyncConfig() }.store(in: &cancellables)
        settings.$cosRegion.sink { _ in pushSyncConfig() }.store(in: &cancellables)
        settings.$cosBucket.sink { _ in pushSyncConfig() }.store(in: &cancellables)
        settings.$cosEndpointHost.sink { _ in pushSyncConfig() }.store(in: &cancellables)
        settings.$cosKeyPrefix.sink { _ in pushSyncConfig() }.store(in: &cancellables)
        settings.$cosRetryAttempts.sink { _ in pushSyncConfig() }.store(in: &cancellables)
        settings.$cosRetryBackoffSeconds.sink { _ in pushSyncConfig() }.store(in: &cancellables)
        settings.$customSyncFolders.sink { _ in pushSyncConfig() }.store(in: &cancellables)
        syncService.updateInterval(minutes: settings.cosSyncIntervalMinutes)
        settings.$cosSyncIntervalMinutes
            .sink { [weak syncService] minutes in syncService?.updateInterval(minutes: minutes) }
            .store(in: &cancellables)
        if settings.cloudBackupEnabled {
            syncService.start()
        }
        settings.$cloudBackupEnabled
            .dropFirst()
            .sink { [weak syncService] on in
                if on { syncService?.start() } else { syncService?.stop() }
            }
            .store(in: &cancellables)

        // 启动即显示主窗口（常规应用）
        window.show()

        // 设置 → 灵动岛行为
        island.viewModel.autoDismissSeconds = settings.autoDismissSeconds
        settings.$autoDismissSeconds
            .sink { [weak island] seconds in island?.viewModel.autoDismissSeconds = seconds }
            .store(in: &cancellables)
        island.viewModel.showStartTime = settings.showStartTime
        settings.$showStartTime
            .sink { [weak island] value in island?.viewModel.showStartTime = value }
            .store(in: &cancellables)
        island.viewModel.onToggleTimeMode = { [weak settings] in
            settings?.showStartTime.toggle()
        }

        // 健康提示：vibe coding 过久/会话过多/深夜关怀
        let wellness = WellnessMonitor(settings: settings, store: store) { [weak island, weak mascot] notice in
            island?.viewModel.enqueueNotice(notice)
            mascot?.viewModel.showNotice(notice.headline)
        }
        wellness.start()
        wellnessMonitor = wellness

        // 首次启动：引导到设置页一键安装（窗口已显示，这里只切页签）
        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { [weak self] in
                    self?.mainWindow?.show(tab: .settings)
                }
            }
        }

        // 管道在自己的队列回调；main.async 保证 FIFO 顺序后接回 MainActor。
        // auditHandler 是旁路：Claude PostToolUse 操作直接进审计服务，不经 TaskStore。
        let pipeline = EventPipeline(
            spoolRoot: SpoolPaths.root(),
            auditHandler: { [weak auditService] event, isStale in
                auditService?.ingestClaude(event, isStale: isStale)
            }
        ) { [weak self] event, isStale in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handle(event, isStale: isStale)
                }
            }
        }
        pipeline.start()
        self.pipeline = pipeline

        // hook 丢失兜底：定期清理长时间无活动的"幽灵"任务
        reapTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let effects = self.store.reapStaleTasks(now: Date(), runningTimeout: 4 * 3600)
                if !effects.isEmpty {
                    self.applyToUI(effects: effects, isStale: true)
                }
            }
        }

        render()
        logLine("启动完成 spool=\(SpoolPaths.root().path)")
    }

    /// 外观主题：system=跟随系统（nil）/ light / dark
    private static func applyAppearance(_ mode: String) {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// 点击 Dock 图标（或无窗口时重新打开）→ 前置主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        mainWindow?.show()
        return true
    }

    private func handle(_ event: TaskEvent, isStale: Bool) {
        // 积压的"存活信号"不进状态机：孤立的过期心跳/等待/会话开始
        // 不代表现在还活着，照单全收会造出一堆幽灵会话
        if isStale {
            switch event.kind {
            case .activity, .waiting, .sessionStarted, .contextUpdate, .titleUpdate,
                 .subagentsUpdated:
                return
            case .taskStarted, .taskFinished, .sessionEnded:
                break  // 开始/结束要进历史与配对
            }
        }
        applyToUI(effects: store.apply(event), isStale: isStale)
    }

    /// 把状态机副作用投影到 UI 与历史（积压/过期事件只入历史，不弹岛）
    private func applyToUI(effects: [TaskStoreEffect], isStale: Bool) {
        guard let island = islandController else { return }
        for effect in effects {
            switch effect {
            case .taskFinished(let task):
                let duration = task.duration.map { String(format: "%.0f秒", $0) } ?? "未知耗时"
                logLine("完成 \(task.id) [\(task.outcome.rawValue)] \(duration) \(task.title ?? "")\(isStale ? " (积压)" : "")")
                usageService.recordFinished(task)
                let wantCard = task.outcome == .success
                    ? settings.notifyCompletion
                    : settings.notifyError
                if !isStale && wantCard {
                    island.viewModel.enqueueFinished(task)
                }
                if !isStale {
                    mascotController?.viewModel.showFinished(success: task.outcome == .success)
                }
            case .taskWaiting(let task):
                logLine("等待 \(task.id) \(task.title ?? "")")
                if !isStale && settings.notifyWaiting {
                    island.viewModel.enqueueWaiting(task)
                }
            case .activeTasksChanged:
                break
            }
        }
        island.viewModel.updateActiveTasks(
            store.sortedActiveTasks, idle: store.sortedIdleTasks)
        mascotController?.viewModel.updateActiveTasks(
            active: store.sortedActiveTasks, idle: store.sortedIdleTasks)
        render()
    }

    private func render() {
        let tasks = store.sortedActiveTasks
        statusController?.update(tasks: tasks)
        let waitingCount = tasks.filter {
            if case .waiting = $0.phase { return true } else { return false }
        }.count
        logLine("active=\(tasks.count) waiting=\(waitingCount) idle=\(store.sortedIdleTasks.count)")
    }

    /// 开发模式可观测性：stdout 单行日志，e2e 脚本据此断言（.app 包内运行时无害）
    private func logLine(_ message: String) {
        print("[eureka] \(message)")
        fflush(stdout)
    }
}
