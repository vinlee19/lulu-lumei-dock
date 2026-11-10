import EurekaIngest
import Foundation

func mcpToolPermissionTests(_ t: TestRunner) {
    t.suite("MCPToolPermissionIndex（工具允许状态，只读）")

    t.test("Claude 规则：deny → ask → allow；用户级全局生效，项目级只在该项目") {
        var index = MCPToolPermissionIndex()
        index.addClaudeSettings(Data("""
        {"env": {"SOME_TOKEN": "must-never-be-read"},
         "permissions": {
           "allow": ["mcp__github", "mcp__notion__notion-search", "Bash(ls:*)", "mcp__*"],
           "ask": ["mcp__github__delete_*"],
           "deny": ["mcp__github__delete_repo", "mcp__bad(x)"]}}
        """.utf8), path: "/home/.claude/settings.json")
        index.addClaudeSettings(Data("""
        {"permissions": {"deny": ["mcp__notion__*"]}}
        """.utf8), path: "/repo/.claude/settings.json", projectName: "repo", projectPath: "/repo")

        try expect(!index.claudeRules.contains { $0.pattern.hasPrefix("Bash") }, "只收 MCP 规则")
        try expect(!index.claudeRules.contains { $0.pattern == "mcp__*" && $0.decision == .allowed },
            "未锚定服务器前缀的 allow 通配被 Claude Code 忽略")
        try expect(!index.claudeRules.contains { $0.pattern.contains("(") }, "带括号的 mcp 规则被忽略")

        try expectEqual(index.claudeAccess(server: "github", tool: "list_issues").everywhere, .allowed)
        try expectEqual(index.claudeAccess(server: "github", tool: "delete_branch").everywhere, .ask,
            "ask 先于 allow")
        let deleteRepo = index.claudeAccess(server: "github", tool: "delete_repo")
        try expectEqual(deleteRepo.everywhere, .denied, "deny 最先")
        try expectEqual(deleteRepo.rules.map(\.decision), [.denied, .ask, .allowed])
        try expect(index.claudeAccess(server: "memory", tool: "read_graph").everywhere == nil,
            "没有规则 = 首次使用时询问")

        let search = index.claudeAccess(server: "notion", tool: "notion-search")
        try expectEqual(search.everywhere, .allowed, "项目级 deny 不影响全局结论")
        try expectEqual(search.rules.last?.projectName, "repo")
        try expectEqual(search.rules.last?.decision, .denied)
    }

    t.test("Claude 工具名归一：非 [A-Za-z0-9_-] 换成下划线") {
        try expectEqual(
            MCPToolPermissionIndex.claudeToolName(server: "my server.v2", tool: "get/item"),
            "mcp__my_server_v2__get_item")
        var index = MCPToolPermissionIndex()
        index.addClaudeSettings(
            Data(#"{"permissions":{"allow":["mcp__my_server_v2__get_*"]}}"#.utf8), path: "/s.json")
        try expectEqual(
            index.claudeAccess(server: "my server.v2", tool: "get/item").everywhere, .allowed)
        try expect(index.claudeAccess(server: "my server.v2", tool: "put").everywhere == nil)
    }

    t.test(".mcp.json 批准状态：拒绝优先；enableAll / 点名批准；未记录 = 待询问") {
        var index = MCPToolPermissionIndex()
        index.addClaudeSettings(
            Data(#"{"disabledMcpjsonServers":["blocked"]}"#.utf8), path: "/home/.claude/settings.json")
        index.addClaudeSettings(
            Data(#"{"enabledMcpjsonServers":["db","blocked"]}"#.utf8),
            path: "/a/.claude/settings.local.json", projectName: "a", projectPath: "/a")
        index.addClaudeSettings(
            Data(#"{"enableAllProjectMcpServers":true}"#.utf8),
            path: "/b/.claude/settings.local.json", projectName: "b", projectPath: "/b")
        try expectEqual(index.claudeProjectServerApproval(server: "db", projectPath: "/a"), .approved)
        try expectEqual(index.claudeProjectServerApproval(server: "blocked", projectPath: "/a"), .rejected)
        try expectEqual(index.claudeProjectServerApproval(server: "other", projectPath: "/a"), .unanswered)
        try expectEqual(index.claudeProjectServerApproval(server: "anything", projectPath: "/b"), .approved)
        try expectEqual(index.claudeProjectServerApproval(server: "db", projectPath: "/c"), .unanswered,
            "别的项目的批准不外溢")
    }

    t.test("Codex：enabled_tools 允许列表、disabled_tools 其后应用、审批模式原样保留") {
        let servers = MCPToolPermissionIndex.parseCodexConfig("""
        model = "gpt"
        [mcp_servers.browser]
        command = "npx"
        enabled_tools = ["open", "screenshot"]
        disabled_tools = ["screenshot"]  # applied after enabled_tools
        default_tools_approval_mode = "prompt"

        [mcp_servers.browser.env]
        API_KEY = "must-not-matter"

        [mcp_servers.browser.tools.open]
        approval_mode = "approve"

        [mcp_servers."My Docs"]
        url = "https://example.com/mcp"
        disabled_tools = [
          "delete_page",
          "purge",
        ]

        [other.section]
        enabled_tools = ["nope"]
        """)
        var index = MCPToolPermissionIndex()
        try expect(index.codexAccess(server: "browser", tool: "open") == nil, "空索引没有结论")
        index = MCPToolPermissionIndex()
        try expectEqual(servers["browser"]?.enabledTools, ["open", "screenshot"])
        try expectEqual(servers["browser"]?.disabledTools, ["screenshot"])
        try expectEqual(servers["browser"]?.defaultApprovalMode, "prompt")
        try expectEqual(servers["browser"]?.toolApprovalModes, ["open": "approve"])
        try expectEqual(servers["my docs"]?.disabledTools, ["delete_page", "purge"], "跨行数组")
        try expect(servers["my docs"]?.enabledTools == nil, "未写允许列表 = 全部暴露")
        try expectEqual(servers.count, 2)
    }

    t.test("glob：* 匹配任意串，其余按字面") {
        try expect(MCPToolPermissionIndex.claudeToolName(server: "a", tool: "b") == "mcp__a__b")
        var index = MCPToolPermissionIndex()
        index.addClaudeSettings(
            Data(#"{"permissions":{"deny":["mcp__*"],"ask":["mcp__a__*_x"]}}"#.utf8), path: "/s.json")
        try expectEqual(index.claudeAccess(server: "zzz", tool: "t").everywhere, .denied,
            "deny / ask 允许 mcp__* 通配")
        try expectEqual(index.claudeAccess(server: "a", tool: "run_x").rules.map(\.pattern),
            ["mcp__*", "mcp__a__*_x"])
        try expectEqual(index.claudeAccess(server: "a", tool: "run_y").rules.map(\.pattern), ["mcp__*"])
    }

    t.test("自动探测策略：没有新鲜结果才探；刚失败不重试；等用户授权的不催") {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func cache(age: TimeInterval, error: String? = nil) -> MCPToolCacheEntry {
            MCPToolCacheEntry(
                toolCount: 1, toolNames: ["a"], schemaTokens: 1, toolsError: error,
                measuredAt: now.addingTimeInterval(-age))
        }
        func snapshot(_ tone: String, age: TimeInterval) -> MCPProbeSnapshot {
            MCPProbeSnapshot(label: "x", tone: tone, checkedAt: now.addingTimeInterval(-age))
        }
        try expect(MCPProbePolicy.shouldAutoProbe(cache: nil, snapshots: [], now: now), "从未探测")
        try expect(!MCPProbePolicy.shouldAutoProbe(cache: cache(age: 3600), snapshots: [], now: now))
        try expect(MCPProbePolicy.shouldAutoProbe(
            cache: cache(age: 8 * 24 * 3600), snapshots: [snapshot("ok", age: 8 * 24 * 3600)],
            now: now), "超过 7 天刷新")
        try expect(!MCPProbePolicy.shouldAutoProbe(
            cache: nil, snapshots: [snapshot("bad", age: 60)], now: now), "一分钟前刚失败")
        try expect(MCPProbePolicy.shouldAutoProbe(
            cache: nil, snapshots: [snapshot("bad", age: 3600)], now: now), "一小时前失败可重试")
        try expect(!MCPProbePolicy.shouldAutoProbe(
            cache: nil, snapshots: [snapshot("warning", age: 3600)], now: now), "需要授权：等用户")
        try expect(MCPProbePolicy.shouldAutoProbe(
            cache: cache(age: 3600, error: "x"), snapshots: [snapshot("ok", age: 3600)], now: now),
            "上次没读到工具列表 → 再试")
        try expect(!MCPProbePolicy.shouldAutoProbe(
            cache: cache(age: 30, error: "x"), snapshots: [snapshot("ok", age: 30)], now: now))
    }
}
