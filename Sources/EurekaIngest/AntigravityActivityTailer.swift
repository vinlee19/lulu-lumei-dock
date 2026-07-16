import Foundation
import EurekaKit

/// Antigravity 活动监视：轮询 conversations/<uuid>.db 的写入（mtime）判会话在跑/空闲。
/// 内容是 protobuf blob，取不到"正在做什么"的文字，故只发无细节的 running/idle 生命周期：
/// 有新写入 → running（taskStarted/activity）；静默超 idleThreshold → taskFinished→空闲。
/// 与 opencode/grok tailer 同为无 hook 的实时通道；不读 db 内容，规避 live-WAL 只读问题。
public final class AntigravityActivityTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let conversationsRoot: URL
    private let runningWindow: TimeInterval   // 首见/写入多新算"在跑"
    private let idleThreshold: TimeInterval   // 静默多久判 turn 结束
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.antigravity-tailer")
    private var timer: DispatchSourceTimer?

    private struct State {
        var lastMtime: Date
        var lastActivityAt: Date
        var running: Bool
        var cwd: String?
    }
    private var states: [String: State] = [:]  // uuid → state

    static let healthName = "Antigravity 活动监视"

    public init(
        conversationsRoot: URL = AntigravityPaths.conversationsRoot(),
        runningWindow: TimeInterval = 45,
        idleThreshold: TimeInterval = 45,
        handler: @escaping Handler
    ) {
        self.conversationsRoot = conversationsRoot
        self.runningWindow = runningWindow
        self.idleThreshold = idleThreshold
        self.handler = handler
    }

    public func start(pollInterval: TimeInterval = 2) {
        HealthRegistry.shared.register(Self.healthName, expectedInterval: pollInterval)
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

    /// 公开供测试与启动时同步调用
    public func scanOnce(now: Date = Date()) {
        HealthRegistry.shared.beat(Self.healthName)
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: conversationsRoot, includingPropertiesForKeys: nil)) ?? []
        for db in files where db.pathExtension == "db" {
            let uuid = db.deletingPathExtension().lastPathComponent
            guard let mtime = AntigravityPaths.newestMtime(dbURL: db) else { continue }
            inspect(uuid: uuid, dbURL: db, mtime: mtime, now: now)
        }
        reapIdle(now: now)
    }

    private func inspect(uuid: String, dbURL: URL, mtime: Date, now: Date) {
        func cwd() -> String? {
            if states[uuid]?.cwd == nil {
                let c = AntigravityPaths.cwd(dbURL: dbURL)
                states[uuid]?.cwd = c
                return c
            }
            return states[uuid]?.cwd
        }
        func emit(_ kind: TaskEvent.Kind, at ts: Date) {
            HealthRegistry.shared.event(Self.healthName)
            handler(TaskEvent(
                source: .antigravity, sessionId: uuid, kind: kind,
                timestamp: ts, cwd: states[uuid]?.cwd), false)
        }

        guard var state = states[uuid] else {
            // 首见：建基线，不重放历史
            let active = now.timeIntervalSince(mtime) < runningWindow
            states[uuid] = State(
                lastMtime: mtime, lastActivityAt: active ? now : mtime,
                running: active, cwd: nil)
            _ = cwd()  // 缓存工作区
            emit(active ? .taskStarted(title: nil) : .sessionStarted, at: active ? now : mtime)
            return
        }

        if mtime > state.lastMtime {
            // 有新写入 → 活跃
            let wasRunning = state.running
            state.lastMtime = mtime
            state.lastActivityAt = now
            state.running = true
            states[uuid] = state
            _ = cwd()
            emit(wasRunning ? .activity(tool: nil) : .taskStarted(title: nil), at: now)
        }
    }

    /// 在跑但静默超时的会话 → 收尾转空闲（下次有写入再 taskStarted）
    private func reapIdle(now: Date) {
        for (uuid, var state) in states where state.running {
            guard now.timeIntervalSince(state.lastActivityAt) > idleThreshold else { continue }
            state.running = false
            states[uuid] = state
            HealthRegistry.shared.event(Self.healthName)
            handler(TaskEvent(
                source: .antigravity, sessionId: uuid,
                kind: .taskFinished(outcome: .success, title: nil, detail: nil),
                timestamp: now, cwd: state.cwd), false)
        }
    }
}
