import EurekaIngest
import Foundation

/// ProjectRoots.recentCwds aggregation tests: every agent root is replaced by an empty subdirectory
/// of a temp dir, proving session cwds from newer sources like kimi/codebuddy/qoder/cursor reach
/// project-level discovery; real ~/ is never touched.
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
        // Empty root set: no source finds anything → empty (if the real ~/ default roots leaked in,
        // this would be non-empty)
        try expectEqual(recentCwdsFrom(base: base), [])

        try plantKimiSession(base: base, cwd: "/Users/me/work/shared-proj")
        try plantCodeBuddySession(base: base, cwd: "/Users/me/work/shared-proj")
        try plantQoderSession(base: base, cwd: "/Users/me/work/shared-proj")
        let cwds = recentCwdsFrom(base: base)
        try expectEqual(cwds, ["/Users/me/work/shared-proj"], "同一 cwd 应只出现一次")
    }
}

// MARK: - fixture setup

private func makeProjectRootsBase() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("eureka-projroots-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// Calls recentCwds with all 13 source roots replaced by (possibly nonexistent) empty
/// subdirectories under base. Indexers return nothing for missing directories, so sources without
/// fixtures yield nothing; opencode/hermes stay off by default. ⚠️ The cursor and trae roots must
/// be passed explicitly too: omit them and the real ~/Library/Application
/// Support/Cursor/…/state.vscdb and ~/.trae-cn/memory get read, and the tests are no longer
/// self-contained (when trae was added, these cases were the first to fail, pulling in cwds from
/// the real ~/).
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

/// trae session: the session DB is encrypted and unreadable → can only be inferred from the
/// plaintext memory library. The directory name is `<forward-encoded cwd>--p<N>-<hash>`; the cwd
/// comes from forward-matching the folder in workspace.json.
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

/// cursor session: sessions live in state.vscdb; the cwd is looked up via
/// workspaceStorage/<id>/workspace.json
private func plantCursorSession(base: URL, cwd: String) throws {
    let cursor = base.appendingPathComponent("cursor", isDirectory: true)
    let fixture = try CursorFixture(root: cursor)
    try fixture.addWorkspace(id: "ws1", folder: cwd)
    try fixture.addComposer(
        id: "c-cursor", workspaceId: "ws1", name: "会话", status: "completed",
        bubbles: [.user("你好")])
}

/// kimi session: <base>/kimi/wd_demo_ea973e2e828f/session_abc/state.json (workDir carries the cwd)
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

/// codebuddy session: <base>/codebuddy/<slug>/<sessionId>.jsonl (inline cwd field)
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

/// qoder session: <base>/qoder/<slug>/<sessionId>.jsonl (the workspace-directories line carries the
/// cwd)
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
