import Foundation
import EurekaKit

/// 监听 spool/events 目录，把事件文件解码为领域事件交给 handler。
/// 消费协议：events/ → rename 到 processing/ → handler → 删除；
/// 启动时先重放 processing/ 残留（上次崩溃未删的），再排空 events/ 积压。
public final class SpoolConsumer {
    /// isStale = 事件落地时间距今超过阈值（开机排空积压时只入历史，不触发岛动画）
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let root: URL
    private let staleThreshold: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.spool")
    private var dirSource: DispatchSourceFileSystemObject?
    public private(set) var undecodableCount = 0

    private var eventsDir: URL { SpoolPaths.eventsDir(root: root) }
    private var processingDir: URL { SpoolPaths.processingDir(root: root) }

    public init(root: URL, staleThreshold: TimeInterval = 300, handler: @escaping Handler) {
        self.root = root
        self.staleThreshold = staleThreshold
        self.handler = handler
    }

    /// 开始监听。handler 在内部队列回调，调用方自行切主线程。
    public func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: processingDir, withIntermediateDirectories: true)

        queue.async {
            self.replayProcessingLeftovers()
            self.drainOnce()
        }

        let fd = open(eventsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: queue
        )
        source.setEventHandler { [weak self] in self?.drainOnce() }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
    }

    public func stop() {
        dirSource?.cancel()
        dirSource = nil
    }

    /// 排空 events/ 中的待处理文件（公开供测试与启动排空直接调用，同步执行）
    public func drainOnce() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension == "json" {
            let dst = processingDir.appendingPathComponent(url.lastPathComponent)
            do {
                try fm.moveItem(at: url, to: dst)
            } catch {
                continue  // 多实例竞争同一文件时让对方处理
            }
            process(fileURL: dst)
            try? fm.removeItem(at: dst)
        }
    }

    private func replayProcessingLeftovers() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: processingDir, includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension == "json" {
            process(fileURL: url)
            try? fm.removeItem(at: url)
        }
    }

    private func process(fileURL: URL) {
        guard
            let data = try? Data(contentsOf: fileURL),
            let raw = RawEvent(data: data)
        else {
            undecodableCount += 1
            return
        }
        let isStale = Date().timeIntervalSince(raw.receivedAt) > staleThreshold
        for event in EventRouter.route(raw) {
            handler(event, isStale)
        }
    }
}
