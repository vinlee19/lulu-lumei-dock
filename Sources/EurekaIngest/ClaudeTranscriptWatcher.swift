import Foundation
import EurekaKit

/// Claude transcript 常驻监视器：不依赖 hooks 的兜底事件源
/// （与 CodexRolloutTailer 对等）。
///
/// 为什么必须有：hooks 在会话启动时加载——装 hooks 之前开的老会话、
/// 或 hooks 配置异常的会话，永远不发任何事件。本监视器轮询 transcript
/// 写入并用尾窗分类（ClaudeSessionBootstrap.classify）感知开始/完成。
/// 对有 hooks 的会话它是冗余信号：TaskStore 的幂等语义 +
/// "空闲会话的重复完成事件不出卡"规则负责去重。
public final class ClaudeTranscriptWatcher {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let projectsRoot: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.claude-watcher")
    private var timer: DispatchSourceTimer?

    private struct FileState {
        var mtime: Date
        var running: Bool
        var knownTitle: String?
        var contextBucket: Int?
    }
    private var states: [String: FileState] = [:]

    public init(projectsRoot: URL, handler: @escaping Handler) {
        self.projectsRoot = projectsRoot
        self.handler = handler
    }

    public func start(pollInterval: TimeInterval = 5) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.scanOnce() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 公开供测试与启动首扫
    public func scanOnce(now: Date = Date(), idleWindow: TimeInterval = 1800) {
        let fm = FileManager.default
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
        for projectDir in projectDirs {
            let files = (try? fm.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                guard now.timeIntervalSince(mtime) < idleWindow else { continue }
                inspect(file, mtime: mtime, now: now)
            }
        }
        // 早已沉寂的文件状态剪枝
        states = states.filter { now.timeIntervalSince($0.value.mtime) < idleWindow * 2 }
    }

    private func inspect(_ file: URL, mtime: Date, now: Date) {
        let path = file.path
        let previous = states[path]
        // 没有新写入就不读
        if let previous, previous.mtime >= mtime { return }
        guard let snapshot = ClaudeSessionBootstrap.classify(fileURL: file) else { return }

        func emit(_ kind: TaskEvent.Kind, at date: Date) {
            handler(TaskEvent(
                source: .claude, sessionId: snapshot.sessionId, kind: kind,
                timestamp: date, cwd: snapshot.cwd, transcriptPath: path
            ), false)
        }

        let wasRunning = previous?.running
        if snapshot.running {
            if wasRunning == true {
                // 状态未变：保持任务活性（防 4h 误回收）
                emit(.activity(tool: nil), at: mtime)
            } else {
                // 初见即在跑 / 空闲后开新 turn
                emit(.taskStarted(title: snapshot.promptText.flatMap { summarizeTitle($0) }),
                     at: snapshot.promptAt ?? snapshot.earliestAt ?? mtime)
            }
        } else if wasRunning == nil {
            emit(.sessionStarted, at: mtime)
        } else if wasRunning == true {
            // turn 收尾：对无 hooks 会话这是唯一的完成信号；
            // 有 hooks 时 Stop 先到、会话已转空闲 → store 抑制重复卡
            emit(.taskFinished(outcome: .success, title: nil, detail: nil),
                 at: snapshot.turnEndAt ?? mtime)
        }

        // 标题/上下文有变化才发
        if let aiTitle = snapshot.aiTitle, aiTitle != previous?.knownTitle {
            emit(.titleUpdate(title: aiTitle), at: mtime)
        }
        let bucket = snapshot.contextPercent.map { Int($0.rounded()) }
        if let percent = snapshot.contextPercent, bucket != previous?.contextBucket {
            emit(.contextUpdate(percent: percent), at: mtime)
        }

        states[path] = FileState(
            mtime: mtime,
            running: snapshot.running,
            knownTitle: snapshot.aiTitle ?? previous?.knownTitle,
            contextBucket: bucket ?? previous?.contextBucket
        )
    }
}
