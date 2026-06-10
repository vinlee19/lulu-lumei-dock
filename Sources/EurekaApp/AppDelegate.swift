import AppKit
import EurekaIngest
import EurekaKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let store = TaskStore()
    private var pipeline: EventPipeline?
    private var reapTimer: Timer?
    private var islandController: IslandPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        let island = IslandPanelController()
        island.start()
        islandController = island

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

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "✦"
        item.button?.toolTip = "Eureka"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "退出 Eureka",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        item.menu = menu
        statusItem = item
    }

    private func handle(_ event: TaskEvent, isStale: Bool) {
        applyToUI(effects: store.apply(event), isStale: isStale)
    }

    /// 把状态机副作用投影到 UI（积压/过期事件只记录，不弹岛）
    private func applyToUI(effects: [TaskStoreEffect], isStale: Bool) {
        guard let island = islandController else { return }
        for effect in effects {
            switch effect {
            case .taskFinished(let task):
                let duration = task.duration.map { String(format: "%.0f秒", $0) } ?? "未知耗时"
                logLine("完成 \(task.id) [\(task.outcome.rawValue)] \(duration) \(task.title ?? "")\(isStale ? " (积压)" : "")")
                if !isStale {
                    island.viewModel.enqueueFinished(task)
                }
                // M5：写入历史
            case .taskWaiting(let task):
                logLine("等待 \(task.id) \(task.title ?? "")")
                if !isStale {
                    island.viewModel.enqueueWaiting(task)
                }
            case .activeTasksChanged:
                break
            }
        }
        island.viewModel.updateActiveTasks(store.sortedActiveTasks)
        render()
    }

    private func render() {
        let tasks = store.sortedActiveTasks
        let waitingCount = tasks.filter {
            if case .waiting = $0.phase { return true } else { return false }
        }.count

        let title: String
        if tasks.isEmpty {
            title = "✦"
        } else if waitingCount > 0 {
            title = "⏳\(tasks.count)"
        } else {
            title = "▶\(tasks.count)"
        }
        statusItem?.button?.title = title
        logLine("active=\(tasks.count) waiting=\(waitingCount)")
    }

    /// 开发模式可观测性：stdout 单行日志，e2e 脚本据此断言（.app 包内运行时无害）
    private func logLine(_ message: String) {
        print("[eureka] \(message)")
        fflush(stdout)
    }
}
