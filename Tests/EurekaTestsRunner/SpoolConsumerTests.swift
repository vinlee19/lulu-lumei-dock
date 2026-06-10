import Foundation
import EurekaIngest
import EurekaKit

func spoolConsumerTests(_ t: TestRunner) {
    t.suite("SpoolConsumer")

    func makeSpool() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: SpoolPaths.eventsDir(root: root), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: SpoolPaths.processingDir(root: root), withIntermediateDirectories: true)
        return root
    }

    func writeEnvelope(
        root: URL, name: String, channel: String = "claude-hook",
        receivedAtMs: Int? = nil, payload: [String: Any]
    ) throws {
        let envelope: [String: Any] = [
            "v": 1,
            "channel": channel,
            "receivedAtMs": receivedAtMs ?? Int(Date().timeIntervalSince1970 * 1000),
            "payload": payload,
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        try data.write(to: SpoolPaths.eventsDir(root: root).appendingPathComponent(name))
    }

    t.test("drainOnce 按文件名顺序消费并删除文件") {
        let root = try makeSpool()
        try writeEnvelope(root: root, name: "002-b.json", payload: [
            "hook_event_name": "Stop", "session_id": "s1",
        ])
        try writeEnvelope(root: root, name: "001-a.json", payload: [
            "hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt": "任务",
        ])

        var received: [TaskEvent] = []
        let consumer = SpoolConsumer(root: root) { event, _ in received.append(event) }
        consumer.drainOnce()

        try expectEqual(received.count, 2)
        guard case .taskStarted = received[0].kind else {
            throw ExpectationError(description: "应先消费 001（taskStarted）")
        }
        guard case .taskFinished = received[1].kind else {
            throw ExpectationError(description: "再消费 002（taskFinished）")
        }
        let leftEvents = try FileManager.default.contentsOfDirectory(
            atPath: SpoolPaths.eventsDir(root: root).path)
        let leftProcessing = try FileManager.default.contentsOfDirectory(
            atPath: SpoolPaths.processingDir(root: root).path)
        try expect(leftEvents.isEmpty && leftProcessing.isEmpty, "消费后应清空目录")
    }

    t.test("过期事件标记 stale，新事件不标记") {
        let root = try makeSpool()
        let oldMs = Int((Date().timeIntervalSince1970 - 3600) * 1000)
        try writeEnvelope(root: root, name: "001-old.json", receivedAtMs: oldMs, payload: [
            "hook_event_name": "Stop", "session_id": "old",
        ])
        try writeEnvelope(root: root, name: "002-new.json", payload: [
            "hook_event_name": "Stop", "session_id": "new",
        ])

        var staleFlags: [String: Bool] = [:]
        let consumer = SpoolConsumer(root: root) { event, isStale in
            staleFlags[event.sessionId] = isStale
        }
        consumer.drainOnce()
        try expectEqual(staleFlags["old"], true)
        try expectEqual(staleFlags["new"], false)
    }

    t.test("坏文件计数并清理，不影响后续消费") {
        let root = try makeSpool()
        try Data("not json at all".utf8).write(
            to: SpoolPaths.eventsDir(root: root).appendingPathComponent("001-bad.json"))
        try writeEnvelope(root: root, name: "002-good.json", payload: [
            "hook_event_name": "Stop", "session_id": "ok",
        ])

        var received: [TaskEvent] = []
        let consumer = SpoolConsumer(root: root) { event, _ in received.append(event) }
        consumer.drainOnce()
        try expectEqual(received.count, 1)
        try expectEqual(consumer.undecodableCount, 1)
        let left = try FileManager.default.contentsOfDirectory(
            atPath: SpoolPaths.eventsDir(root: root).path)
        try expect(left.isEmpty, "坏文件也应被清理")
    }
}
