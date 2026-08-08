import EurekaIngest
import Foundation

/// ProjectRoots.recentCwds 聚合测试：全部 agent 根用临时目录里的空子目录顶替，
/// 证明 kimi/codebuddy/qoder/cursor 等新源的会话 cwd 也能进入项目级发现；全程不碰真实 ~/。
func projectRootsTests(_ t: TestRunner) {
    t.suite("ProjectRoots")

    t.test("kimi 会话 cwd 进入 recentCwds（其它根全空）") {
        let base = try makeProjectRootsBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try plantKimiSession(base: base, cwd: "/Users/me/work/kimi-only-proj")
        let cwds = recentCwdsFrom(base: base)
        try expectEqual(cwds, ["/Users/me/work/kimi-only-proj"])
    }

    t.test("codebuddy 会话 cwd 进入 recentCwds（其它根全空）") {
        let base = try makeProjectRootsBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try plantCodeBuddySession(base: base, cwd: "/work/cb-only-proj")
        let cwds = recentCwdsFrom(base: base)
        try expectEqual(cwds, ["/work/cb-only-proj"])
    }

    t.test("qoder 会话 cwd 进入 recentCwds（其它根全空）") {
        let base = try makeProjectRootsBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try plantQoderSession(base: base, cwd: "/Users/me/work/qoder-only-proj")
        let cwds = recentCwdsFrom(base: base)
        try expectEqual(cwds, ["/Users/me/work/qoder-only-proj"])
    }

    t.test("cursor 会话 cwd 进入 recentCwds（经 workspaceStorage 反查）") {
        let base = try makeProjectRootsBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try plantCursorSession(base: base, cwd: "/Users/me/work/cursor-only-proj")
        let cwds = recentCwdsFrom(base: base)
        try expectEqual(cwds, ["/Users/me/work/cursor-only-proj"])
    }

    t.test("trae 会话 cwd 进入 recentCwds（经记忆库目录名正向编码 + workspace.json 反查）") {
        let base = try makeProjectRootsBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try plantTraeSession(base: base, cwd: "/Users/me/work/trae-only-proj")
        let cwds = recentCwdsFrom(base: base)
        try expectEqual(cwds, ["/Users/me/work/trae-only-proj"])
    }

    t.test("多源同 cwd 去重；全空根集返回空（不碰真实 ~/）") {
        let base = try makeProjectRootsBase()
        defer { try? FileManager.default.removeItem(at: base) }
        // 空根集：任何源都扫不到 → 空（若误用真实 ~/ 默认根，这里会非空）
        try expectEqual(recentCwdsFrom(base: base), [])

        try plantKimiSession(base: base, cwd: "/Users/me/work/shared-proj")
        try plantCodeBuddySession(base: base, cwd: "/Users/me/work/shared-proj")
        try plantQoderSession(base: base, cwd: "/Users/me/work/shared-proj")
        let cwds = recentCwdsFrom(base: base)
        try expectEqual(cwds, ["/Users/me/work/shared-proj"], "同一 cwd 应只出现一次")
    }
}

// MARK: - fixture 搭建

private func makeProjectRootsBase() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("eureka-projroots-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// 以 base 下各（可能不存在的）空子目录顶替全部 13 源的根调 recentCwds。
/// 索引器对缺失目录返回空，故未放 fixture 的源自然无产出；opencode/hermes 保持默认关闭。
/// ⚠️ cursor 与 trae 的根也必须显式传：漏传就会去读真实的
/// ~/Library/Application Support/Cursor/…/state.vscdb 与 ~/.trae-cn/memory，测试不再自洽
/// （加 trae 时就是这几条用例先挂，把真实 ~/ 里的 cwd 带了进来）。
private func recentCwdsFrom(base: URL) -> [String] {
    CursorWorkspaceIndex.resetCacheForTesting()
    defer { CursorWorkspaceIndex.resetCacheForTesting() }
    return
    ProjectRoots.recentCwds(
        claudeProjectsRoot: base.appendingPathComponent("claude", isDirectory: true),
        codexSessionsRoot: base.appendingPathComponent("codex", isDirectory: true),
        kimiSessionsRoot: base.appendingPathComponent("kimi", isDirectory: true),
        geminiTmpRoot: base.appendingPathComponent("gemini-tmp", isDirectory: true),
        geminiProjectsFile: base.appendingPathComponent("gemini-projects.json"),
        qwenProjectsRoot: base.appendingPathComponent("qwen", isDirectory: true),
        grokSessionsRoot: base.appendingPathComponent("grok", isDirectory: true),
        codeBuddyProjectsRoot: base.appendingPathComponent("codebuddy", isDirectory: true),
        qoderProjectsRoot: base.appendingPathComponent("qoder", isDirectory: true),
        antigravityConversationsRoot: base.appendingPathComponent("antigravity", isDirectory: true),
        cursorStateDB: base.appendingPathComponent("cursor/User/globalStorage/state.vscdb"),
        cursorWorkspaceStorageRoot: base.appendingPathComponent(
            "cursor/User/workspaceStorage", isDirectory: true),
        traeMemoryProjectsRoot: base.appendingPathComponent(
            "trae/memory/projects", isDirectory: true),
        traeWorkspaceStorageRoots: [
            base.appendingPathComponent("trae-as/User/workspaceStorage", isDirectory: true)
        ])
}

/// trae 会话：会话库加密读不了 → 只能从明文记忆库反推。
/// 目录名是 `<正向编码 cwd>--p<N>-<hash>`，cwd 靠 workspace.json 的 folder 正向匹配得出。
private func plantTraeSession(base: URL, cwd: String) throws {
    let fm = FileManager.default
    let encoded = SkillMemoryIndexer.encodeProjectDirName(cwd)
    let dayDir = base.appendingPathComponent(
        "trae/memory/projects/\(encoded)--p1-deadbeefcafe/20260807", isDirectory: true)
    try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
    let iso = DateFormatter()
    iso.locale = Locale(identifier: "en_US_POSIX")
    iso.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let stamp = iso.string(from: Date().addingTimeInterval(-600))
    try Data("[session_id: tr1 | topic_summary_time: \(stamp)]分析这个项目".utf8)
        .write(to: dayDir.appendingPathComponent("topics.md"))

    let workspace = base.appendingPathComponent(
        "trae-as/User/workspaceStorage/ws1", isDirectory: true)
    try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
    try Data(#"{"folder":"file://\#(cwd)"}"#.utf8)
        .write(to: workspace.appendingPathComponent("workspace.json"))
}

/// cursor 会话：会话在 state.vscdb 里，cwd 要经 workspaceStorage/<id>/workspace.json 反查
private func plantCursorSession(base: URL, cwd: String) throws {
    let cursor = base.appendingPathComponent("cursor", isDirectory: true)
    let fixture = try CursorFixture(root: cursor)
    try fixture.addWorkspace(id: "ws1", folder: cwd)
    try fixture.addComposer(
        id: "c-cursor", workspaceId: "ws1", name: "会话", status: "completed",
        bubbles: [.user("你好")])
}

/// kimi 会话：<base>/kimi/wd_demo_ea973e2e828f/session_abc/state.json（workDir 带 cwd）
private func plantKimiSession(base: URL, cwd: String) throws {
    let sessionDir = base.appendingPathComponent(
        "kimi/wd_demo_ea973e2e828f/session_abc", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let created = iso.string(from: Date().addingTimeInterval(-3600))
    let updated = iso.string(from: Date().addingTimeInterval(-60))
    let state = #"{"createdAt":"\#(created)","updatedAt":"\#(updated)","title":"真标题","isCustomTitle":false,"workDir":"\#(cwd)"}"#
    try Data(state.utf8).write(to: sessionDir.appendingPathComponent("state.json"))
}

/// codebuddy 会话：<base>/codebuddy/<slug>/<sessionId>.jsonl（行内 cwd 字段）
private func plantCodeBuddySession(base: URL, cwd: String) throws {
    let projectDir = base.appendingPathComponent("codebuddy/-work-demo", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let lines = [
        #"{"id":"u1","timestamp":\#(now - 4000),"type":"message","role":"user","content":[{"type":"input_text","text":"分析一下这个仓库"}],"sessionId":"s-cb","cwd":"\#(cwd)"}"#,
        #"{"id":"s1","timestamp":\#(now - 3000),"type":"summary","summary":"分析仓库","sessionId":"s-cb","cwd":"\#(cwd)"}"#,
    ]
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(
        to: projectDir.appendingPathComponent("s-cb.jsonl"))
}

/// qoder 会话：<base>/qoder/<slug>/<sessionId>.jsonl（workspace-directories 行带 cwd）
private func plantQoderSession(base: URL, cwd: String) throws {
    let projectDir = base.appendingPathComponent("qoder/-work-demo", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let ts = iso.string(from: Date().addingTimeInterval(-60))
    let lines = [
        #"{"type":"workspace-directories","sessionId":"s-qd","directories":["\#(cwd)"]}"#,
        #"{"type":"user","uuid":"u2","timestamp":"\#(ts)","message":{"role":"user","content":"分析项目结构"},"origin":{"kind":"human"},"cwd":"\#(cwd)","sessionId":"s-qd"}"#,
    ]
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(
        to: projectDir.appendingPathComponent("s-qd.jsonl"))
}
