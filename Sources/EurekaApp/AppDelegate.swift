import AppKit
import Combine
import EurekaIngest
import EurekaKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private let store = TaskStore()
    private let usageService = UsageService()
    private let limitsService = RateLimitsService()
    private let settings = AppSettings()
    private let installer = InstallerService()
    private var pipeline: EventPipeline?
    private var reapTimer: Timer?
    private var islandController: IslandPanelController?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 每次启动把随包 relay 同步到稳定路径（升级 app 后 hooks 不断链）
        RelaySyncer.sync()

        statusController = StatusItemController(
            usageService: usageService, limitsService: limitsService,
            settings: settings, installer: installer)
        let island = IslandPanelController()
        island.start()
        islandController = island
        usageService.start()
        limitsService.start()

        // 设置 → 灵动岛行为
        island.viewModel.autoDismissSeconds = settings.autoDismissSeconds
        settings.$autoDismissSeconds
            .sink { [weak island] seconds in island?.viewModel.autoDismissSeconds = seconds }
            .store(in: &cancellables)

        // 首次启动：引导到设置页一键安装
        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { [weak self] in
                    self?.statusController?.showPopover(tab: .settings)
                }
            }
        }

        // 管道在自己的队列回调；main.async 保证 FIFO 顺序后接回 MainActor
        let pipeline = EventPipeline(spoolRoot: SpoolPaths.root()) { [weak self] event, isStale in
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

    private func handle(_ event: TaskEvent, isStale: Bool) {
        // 积压的"存活信号"不进状态机：孤立的过期心跳/等待/会话开始
        // 不代表现在还活着，照单全收会造出一堆幽灵会话
        if isStale {
            switch event.kind {
            case .activity, .waiting, .sessionStarted, .contextUpdate, .titleUpdate:
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
        render()
    }

    private func render() {
        let tasks = store.sortedActiveTasks
        statusController?.update(tasks: tasks)
        let waitingCount = tasks.filter {
            if case .waiting = $0.phase { return true } else { return false }
        }.count
        logLine("active=\(tasks.count) waiting=\(waitingCount)")
    }

    /// 开发模式可观测性：stdout 单行日志，e2e 脚本据此断言（.app 包内运行时无害）
    private func logLine(_ message: String) {
        print("[eureka] \(message)")
        fflush(stdout)
    }
}
