import EurekaIngest
import EurekaKit
import Foundation

func mcpConfigIndexerTests(_ t: TestRunner) {
    t.suite("MCPConfigIndexer（MCP 配置只读索引）")

    /// 把一条 entry 的全部字段拼成一段文本，供"密钥值绝不出现"断言使用
    func flatten(_ entries: [MCPServerEntry]) -> String {
        entries.map {
            [$0.name, $0.transport, $0.commandSummary ?? "", $0.urlSummary ?? "",
             $0.envKeys.joined(separator: " "), $0.projectName ?? "", $0.configPath]
                .joined(separator: " ")
        }.joined(separator: "\n")
    }

    t.test("claude JSON：顶层 mcpServers 解析，projects 子树不收") {
        let data = try fixtureData("mcp-claude.json")
        let entries = MCPConfigIndexer.parseJSONServers(
            data, source: .claude, configPath: "/tmp/.claude.json")
        try expectEqual(entries.map(\.name), ["context7", "linear"])
        try expect(!entries.contains { $0.name == "project-only" },
            "projects 子树里的 server 不该被顶层解析收进来")

        let context7 = entries[0]
        try expectEqual(context7.transport, "stdio")
        try expectEqual(context7.commandSummary, "npx -y @upstash/context7-mcp")
        try expectEqual(context7.envKeys, ["CONTEXT7_API_KEY"])

        let linear = entries[1]
        try expectEqual(linear.transport, "sse")
        try expectEqual(linear.urlSummary, "https://mcp.linear.app/sse", "query 必须剥掉")
        try expectEqual(linear.envKeys, ["Authorization"], "headers 只收键名")
    }

    t.test("密钥红线：env/headers/query 的值绝不出现在任何字段") {
        let data = try fixtureData("mcp-claude.json")
        let entries = MCPConfigIndexer.parseJSONServers(
            data, source: .claude, configPath: "/tmp/.claude.json")
        try expect(!flatten(entries).contains("SECRET"),
            "密钥值泄漏进了模型字段")
    }

    t.test("codex TOML：段头识别、子段归属、相邻段不吞") {
        let text = try fixtureString("mcp-codex.toml")
        let entries = MCPConfigIndexer.parseTOMLServers(
            text, source: .codex, configPath: "/tmp/config.toml")
        try expectEqual(
            entries.map(\.name), ["playwright", "internal-docs", "kimi-style"])
        try expect(!entries.contains { $0.name == "fast" },
            "[profiles.*] 不是 MCP server")

        let playwright = entries[0]
        try expectEqual(playwright.commandSummary, "npx -y @playwright/mcp")
        try expectEqual(playwright.envKeys, ["PLAYWRIGHT_TOKEN"],
            "inline env 只收键名；[mcp_servers.x.tools.y] 逐工具开关不算密钥键")

        let docs = entries[1]
        try expectEqual(docs.urlSummary, "https://docs.internal.example/mcp", "query 必须剥掉")
        try expectEqual(docs.envKeys, ["DOCS_API_KEY", "DOCS_REGION"],
            "[mcp_servers.x.env] 子段归属同一 server 且只收键名")
        try expectEqual(docs.transport, "http")

        let kimiStyle = entries[2]
        try expectEqual(kimiStyle.commandSummary, "uvx", "[mcp.x] 形态（kimi 约定）也要认")
    }

    t.test("codex TOML：密钥值绝不出现在任何字段") {
        let text = try fixtureString("mcp-codex.toml")
        let entries = MCPConfigIndexer.parseTOMLServers(
            text, source: .codex, configPath: "/tmp/config.toml")
        try expect(!flatten(entries).contains("SECRET"), "密钥值泄漏进了模型字段")
    }

    t.test("gemini JSON：httpUrl 形态与 fragment 剥离") {
        let data = try fixtureData("mcp-gemini.json")
        let entries = MCPConfigIndexer.parseJSONServers(
            data, source: .gemini, configPath: "/tmp/settings.json")
        try expectEqual(entries.count, 1)
        try expectEqual(entries[0].name, "figma")
        try expectEqual(entries[0].transport, "http")
        try expectEqual(entries[0].urlSummary, "https://mcp.figma.com/mcp",
            "fragment 也可能带 token，必须剥掉")
    }

    t.test("opencode 方言：mcp 容器、command 数组、environment 键名、enabled、local/remote 归一") {
        let data = try fixtureData("mcp-opencode.json")
        let entries = MCPConfigIndexer.parseJSONServers(
            data, source: .opencode, configPath: "/tmp/opencode.json", container: "mcp")
        try expectEqual(entries.map(\.name), ["dataPro-search", "local-runner"])

        let remote = entries[0]
        try expectEqual(remote.transport, "http", "type=remote 归一为 http")
        try expectEqual(remote.urlSummary, "https://mcp.datapro.example/search", "query 必须剥掉")
        try expectEqual(remote.envKeys, ["X-Agent-Plan-Key"], "headers 只收键名")
        try expectEqual(remote.enabled, true)

        let local = entries[1]
        try expectEqual(local.transport, "stdio", "type=local 归一为 stdio")
        try expectEqual(local.commandSummary, "bun x my-mcp --fast", "command 数组展开为摘要")
        try expectEqual(local.envKeys, ["RUNNER_TOKEN"], "environment 只收键名")
        try expectEqual(local.enabled, false)
        try expect(!flatten(entries).contains("SECRET"), "密钥值泄漏进了模型字段")
    }

    t.test("grok TOML：enabled 字段 + env 子表键名；密钥值不泄漏") {
        let text = try fixtureString("mcp-grok.toml")
        let entries = MCPConfigIndexer.parseTOMLServers(
            text, source: .grok, configPath: "/tmp/grok-config.toml")
        try expectEqual(entries.map(\.name), ["notion", "paused"])
        try expectEqual(entries[0].enabled, true)
        try expectEqual(entries[0].envKeys, ["NOTION_TOKEN"])
        try expectEqual(entries[1].enabled, false)
        try expect(!flatten(entries).contains("SECRET"), "密钥值泄漏进了模型字段")
    }

    t.test("index：新读源全覆盖（cursor/kimi mcp.json、qwen settings、grok toml、opencode）") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("eureka-mcp-idx-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let home = base
        func write(_ rel: String, _ content: String) throws {
            let url = home.appendingPathComponent(rel)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        try write(".cursor/mcp.json", #"{"mcpServers": {"c1": {"url": "https://c"}}}"#)
        // 项目级：<repo>/.mcp.json（claude 约定）与 <repo>/.cursor/mcp.json（cursor 约定）
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(
            at: repo.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        try #"{"mcpServers": {"proj-cursor": {"command": "npx"}}}"#
            .write(to: repo.appendingPathComponent(".cursor/mcp.json"),
                   atomically: true, encoding: .utf8)
        try write(".kimi-code/mcp.json", #"{"mcpServers": {"k1": {"command": "npx"}}}"#)
        try write(".qwen/settings.json",
                  #"{"mcpServers": {"q1": {"type": "stdio", "command": "uvx"}}}"#)
        try write(".grok/config.toml", "[mcp_servers.g1]\ncommand = \"npx\"\n")
        try write(".config/opencode/opencode.json",
                  #"{"mcp": {"o1": {"type": "remote", "url": "https://o"}}}"#)

        let entries = MCPConfigIndexer.index(
            projectRoots: [(root: repo, name: "demo")], home: home)
        let bySource = Dictionary(grouping: entries, by: \.source)
        try expectEqual(bySource[.cursor]?.map(\.name).sorted(), ["c1", "proj-cursor"])
        try expectEqual(
            bySource[.cursor]?.first { $0.name == "proj-cursor" }?.projectName, "demo",
            "项目级 .cursor/mcp.json 要归属项目名")
        try expectEqual(bySource[.kimi]?.map(\.name), ["k1"])
        try expectEqual(bySource[.qwen]?.map(\.name), ["q1"])
        try expectEqual(bySource[.grok]?.map(\.name), ["g1"])
        try expectEqual(bySource[.opencode]?.map(\.name), ["o1"])
    }

    t.test("index：缺失文件安静跳过；项目级 .mcp.json 归属项目名") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("eureka-mcp-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let home = base.appendingPathComponent("home", isDirectory: true)
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try #"{"mcpServers": {"repo-server": {"command": "true"}}}"#
            .write(to: repo.appendingPathComponent(".mcp.json"),
                   atomically: true, encoding: .utf8)

        let entries = MCPConfigIndexer.index(
            projectRoots: [(root: repo, name: "demo-repo")], home: home)
        try expectEqual(entries.count, 1, "空 home 下只应有项目级那一条")
        try expectEqual(entries[0].name, "repo-server")
        try expectEqual(entries[0].projectName, "demo-repo")
        try expectEqual(entries[0].source, .claude)
    }
}
