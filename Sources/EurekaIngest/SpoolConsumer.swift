import Foundation
import EurekaKit

/// Watches the spool/events directory, decodes event files into domain events and hands them to the
/// handler. Consumption protocol: events/ → rename into processing/ → handler → delete; on start,
/// first replay leftovers in processing/ (not deleted before the last crash), then drain the
/// events/ backlog.
public final class SpoolConsumer {
    /// isStale = the event landed longer ago than the threshold (draining the backlog at launch
    /// only writes history, no island animation)
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    /// Side-channel observer: receives the raw envelope (before routing) for side pipelines such as
    /// audit. isStale is passed along.
    public typealias RawObserver = (RawEvent, _ isStale: Bool) -> Void

    private let root: URL
    private let staleThreshold: TimeInterval
    private let handler: Handler
    private let rawObserver: RawObserver?
    private let queue = DispatchQueue(label: "com.vinlee.eureka.spool")
    private var dirSource: DispatchSourceFileSystemObject?
    public private(set) var undecodableCount = 0

    private var eventsDir: URL { SpoolPaths.eventsDir(root: root) }
    private var processingDir: URL { SpoolPaths.processingDir(root: root) }

    public init(
        root: URL, staleThreshold: TimeInterval = 300,
        rawObserver: RawObserver? = nil, handler: @escaping Handler
    ) {
        self.root = root
        self.staleThreshold = staleThreshold
        self.rawObserver = rawObserver
        self.handler = handler
    }

    static let healthName = "事件队列（hooks / notify）"

    /// Start watching. The handler is called back on an internal queue; callers hop to the main
    /// thread themselves.
    public func start() {
        HealthRegistry.shared.register(Self.healthName, expectedInterval: nil)
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

    /// Drain pending files in events/ (public for tests and the launch-time drain; runs
    /// synchronously)
    public func drainOnce() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension == "json" {
            let dst = processingDir.appendingPathComponent(url.lastPathComponent)
            do {
                try fm.moveItem(at: url, to: dst)
            } catch {
                continue  // Another instance raced us for this file; let it handle it
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
            HealthRegistry.shared.failure(
                Self.healthName, note: L10n.format("Cannot parse event file: %@", zhHans: "事件文件无法解析: %@", String(fileURL.lastPathComponent)))
            return
        }
        HealthRegistry.shared.beat(Self.healthName)
        let isStale = Date().timeIntervalSince(raw.receivedAt) > staleThreshold
        rawObserver?(raw, isStale)  // Side channel (audit) before lifecycle routing; the two chains are independent
        for event in EventRouter.route(raw) {
            HealthRegistry.shared.event(Self.healthName)
            handler(event, isStale)
        }
    }
}
