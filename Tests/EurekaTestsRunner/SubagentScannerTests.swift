import Foundation
import EurekaKit
import EurekaIngest

func subagentScannerTests(_ t: TestRunner) {
    t.suite("ClaudeSubagentScanner")

    func loadScan(turnStartedAt: Date? = nil) throws -> [SubagentInfo] {
        let parent = try fixtureURL("subagent-session/sess.jsonl")
        let sessionDir = parent.deletingPathExtension()  // .../subagent-session/sess
        return ClaudeSubagentScanner.scan(
            sessionDir: sessionDir, parentTranscript: parent, turnStartedAt: turnStartedAt)
    }

    func find(_ subs: [SubagentInfo], _ agentId: String) throws -> SubagentInfo {
        guard let sub = subs.first(where: { $0.agentId == agentId }) else {
            throw ExpectationError(description: "没找到子 agent \(agentId)：\(subs.map(\.agentId))")
        }
        return sub
    }

    t.test("扫描 subagents/：解析类型/描述，按 tool_result 判运行/完成/失败") {
        let subs = try loadScan()
        try expectEqual(subs.count, 4)

        let run = try find(subs, "run")
        try expectEqual(run.agentType, "Explore")
        try expectEqual(run.description, "探索 transcript 解析")
        try expectEqual(run.status, .running)
        try expectEqual(run.currentActivity, "WebFetch")  // 子 agent transcript 尾部最后工具

        try expectEqual(try find(subs, "done").status, .completed)
        try expectEqual(try find(subs, "fail").status, .failed)
        // 完成/失败的不读 transcript，无当前工具
        try expectEqual(try find(subs, "done").currentActivity, nil)
    }

    t.test("内联 tool_result 滚出尾窗：tool-results 文件存在即判完成") {
        let off = try find(try loadScan(), "offload")
        try expectEqual(off.status, .completed)
    }

    t.test("无 subagents/ 目录（Codex/无子 agent）→ 空") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-no-subagents-\(UUID().uuidString)")
        let subs = ClaudeSubagentScanner.scan(sessionDir: dir, parentTranscript: nil)
        try expect(subs.isEmpty, "无 subagents/ 目录应返回空")
    }

    t.test("按 turn 起点裁剪：晚于全部 meta 创建时间→空，早于→全留") {
        let future = try loadScan(turnStartedAt: .distantFuture)
        try expect(future.isEmpty, "晚于 turn 起点的应被过滤")
        try expectEqual(try loadScan(turnStartedAt: .distantPast).count, 4)
    }
}
