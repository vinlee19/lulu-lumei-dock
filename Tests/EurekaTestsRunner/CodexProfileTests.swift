import EurekaInstall
import Foundation

func codexProfileTests(_ t: TestRunner) {
    t.suite("CodexProfileEditor")

    let existing = """
    model = "gpt-5.5"
    notify = ["/x/eureka-relay", "codex-notify"]

    [mcp_servers.foo]
    url = "https://x"

    [profiles.fast]
    model = "gpt-5.5"
    model_reasoning_effort = "low"
    """

    t.test("read：解析 [profiles.*] 段的已知键") {
        let profiles = CodexProfileEditor.read(from: existing)
        try expectEqual(profiles.count, 1)
        try expectEqual(profiles[0].name, "fast")
        try expectEqual(profiles[0].model, "gpt-5.5")
        try expectEqual(profiles[0].reasoningEffort, "low")
    }

    t.test("upsert 新增：追加段，保留 notify / mcp_servers") {
        let out = CodexProfileEditor.upsert(into: existing, profile: CodexProfile(
            name: "deep", model: "gpt-5.5", reasoningEffort: "xhigh", personality: "pragmatic"))
        try expect(out.contains("[profiles.deep]"))
        try expect(out.contains("model_reasoning_effort = \"xhigh\""))
        try expect(out.contains("personality = \"pragmatic\""))
        try expect(out.contains("notify = "), "notify 不能被破坏")
        try expect(out.contains("[mcp_servers.foo]"), "mcp_servers 不能被破坏")
        try expectEqual(CodexProfileEditor.read(from: out).count, 2)
    }

    t.test("upsert 改键：改已有段内键、保留未识别键") {
        let withExtra = """
        [profiles.fast]
        model = "gpt-5.5"
        model_reasoning_effort = "low"
        some_unknown = "keep-me"
        """
        let out = CodexProfileEditor.upsert(into: withExtra, profile: CodexProfile(
            name: "fast", model: "gpt-5.5", reasoningEffort: "high"))
        try expect(out.contains("model_reasoning_effort = \"high\""))
        try expect(!out.contains("\"low\""), "旧值应被替换")
        try expect(out.contains("some_unknown = \"keep-me\""), "未识别键应保留")
        try expectEqual(CodexProfileEditor.read(from: out).count, 1)
    }

    t.test("remove：整段删除，其它段不动") {
        let out = CodexProfileEditor.remove(from: existing, name: "fast")
        try expect(!out.contains("[profiles.fast]"))
        try expect(out.contains("[mcp_servers.foo]"), "mcp_servers 不能被删")
        try expect(out.contains("notify = "), "notify 不能被删")
        try expectEqual(CodexProfileEditor.read(from: out).count, 0)
    }
}
