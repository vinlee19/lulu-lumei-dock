import EurekaSync
import Foundation

func syncKeyMapperTests(_ t: TestRunner) {
    t.suite("SyncKeyMapper")

    t.test("sanitizeHost：小写、非法字符折叠、去首尾连字符") {
        try expectEqual(SyncKeyMapper.sanitizeHost("MacBook-Pro.local"), "macbook-pro-local")
        try expectEqual(SyncKeyMapper.sanitizeHost("我的 Mac"), "mac")
        try expectEqual(SyncKeyMapper.sanitizeHost("--a__b--"), "a-b")
        try expectEqual(SyncKeyMapper.sanitizeHost("固"), "unknown-host")
    }

    t.test("deviceNamespace：首次算出后固化，改 hostname 不换命名空间") {
        let suite = "eureka-test-keymapper-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SyncKeyMapper.deviceNamespace(defaults: defaults)
        try expect(!first.isEmpty)
        // 固化后再次调用返回存档值（即使 hostname 变了也不重算）
        defaults.set("frozen-host", forKey: "cosDeviceNamespace")
        try expectEqual(SyncKeyMapper.deviceNamespace(defaults: defaults), "frozen-host")
    }

    t.test("key 拼接：前缀 trim、相对路径去斜杠、空前缀") {
        try expectEqual(
            SyncKeyMapper.key(prefix: "/eureka/", host: "mac", category: "claude/skills",
                              relativePath: "/foo/SKILL.md"),
            "eureka/mac/claude/skills/foo/SKILL.md")
        try expectEqual(
            SyncKeyMapper.key(prefix: "", host: "mac", category: "codex", relativePath: "AGENTS.md"),
            "mac/codex/AGENTS.md")
        try expectEqual(
            SyncKeyMapper.key(prefix: "e", host: "mac", category: "opencode", relativePath: ""),
            "e/mac/opencode")
    }

    t.test("canonicalURIPath：分段编码、中文/空格、斜杠保留") {
        try expectEqual(
            SyncKeyMapper.canonicalURIPath(forKey: "eureka/mac/claude/skills/中文 技能/SKILL.md"),
            "/eureka/mac/claude/skills/%E4%B8%AD%E6%96%87%20%E6%8A%80%E8%83%BD/SKILL.md")
        try expectEqual(SyncKeyMapper.canonicalURIPath(forKey: "a/b"), "/a/b")
    }

    t.test("subagents 深层 jsonl 的键映射") {
        let key = SyncKeyMapper.key(
            prefix: "eureka", host: "mac", category: "claude/projects",
            relativePath: "-Users-me-proj/sess-1/subagents/agent-a.jsonl")
        try expectEqual(key, "eureka/mac/claude/projects/-Users-me-proj/sess-1/subagents/agent-a.jsonl")
    }
}
