import EurekaInstall
import Foundation

func mcpServerEditorTests(_ t: TestRunner) {
    t.suite("MCPServerEditor（MCP 配置写入引擎）")

    let stdioDef = MCPServerDefinition(
        name: "context7", transport: .stdio,
        command: "npx", args: ["-y", "@upstash/context7-mcp"],
        env: ["CONTEXT7_API_KEY": "fake-value"])
    let remoteDef = MCPServerDefinition(
        name: "linear", transport: .remote,
        url: "https://mcp.linear.app/sse",
        headers: ["Authorization": "Bearer fake"], timeout: 30)

    // MARK: JSON 方言

    t.test("typed 方言（claude/qwen）：stdio 写 type=stdio，remote 写 type=http") {
        let stdio = try MCPServerEditor.upsertJSON(
            into: "", definition: stdioDef, container: "mcpServers", style: .typed)
        let root = try MCPServerEditor.parse(stdio)
        let entry = (root["mcpServers"] as? [String: Any])?["context7"] as? [String: Any]
        try expectEqual(entry?["type"] as? String, "stdio")
        try expectEqual(entry?["command"] as? String, "npx")
        try expectEqual((entry?["args"] as? [String]) ?? [], ["-y", "@upstash/context7-mcp"])
        try expectEqual((entry?["env"] as? [String: String])?["CONTEXT7_API_KEY"], "fake-value")

        let remote = try MCPServerEditor.upsertJSON(
            into: "", definition: remoteDef, container: "mcpServers", style: .typed)
        let remoteEntry = (try MCPServerEditor.parse(remote)["mcpServers"]
            as? [String: Any])?["linear"] as? [String: Any]
        try expectEqual(remoteEntry?["type"] as? String, "http")
        try expectEqual(remoteEntry?["url"] as? String, "https://mcp.linear.app/sse")
    }

    t.test("plain 方言（gemini/cursor/kimi）：不写 type；remote 带 timeout") {
        let stdio = try MCPServerEditor.upsertJSON(
            into: "", definition: stdioDef, container: "mcpServers", style: .plain)
        let entry = (try MCPServerEditor.parse(stdio)["mcpServers"]
            as? [String: Any])?["context7"] as? [String: Any]
        try expect(entry?["type"] == nil, "plain 方言不该写 type")
        try expectEqual(entry?["command"] as? String, "npx")

        let remote = try MCPServerEditor.upsertJSON(
            into: "", definition: remoteDef, container: "mcpServers", style: .plain)
        let remoteEntry = (try MCPServerEditor.parse(remote)["mcpServers"]
            as? [String: Any])?["linear"] as? [String: Any]
        try expectEqual(remoteEntry?["timeout"] as? Int, 30)
        try expectEqual(
            (remoteEntry?["headers"] as? [String: String])?["Authorization"], "Bearer fake")
    }

    t.test("opencode 方言：command 数组、environment 键、enabled=true、容器是 mcp") {
        let stdio = try MCPServerEditor.upsertJSON(
            into: "", definition: stdioDef, container: "mcp", style: .opencode)
        let entry = (try MCPServerEditor.parse(stdio)["mcp"]
            as? [String: Any])?["context7"] as? [String: Any]
        try expectEqual(entry?["type"] as? String, "local")
        try expectEqual(
            (entry?["command"] as? [String]) ?? [],
            ["npx", "-y", "@upstash/context7-mcp"], "opencode 的 command 是含可执行的数组")
        try expectEqual(
            (entry?["environment"] as? [String: String])?["CONTEXT7_API_KEY"], "fake-value")
        try expectEqual(entry?["enabled"] as? Bool, true)

        let remote = try MCPServerEditor.upsertJSON(
            into: "", definition: remoteDef, container: "mcp", style: .opencode)
        let remoteEntry = (try MCPServerEditor.parse(remote)["mcp"]
            as? [String: Any])?["linear"] as? [String: Any]
        try expectEqual(remoteEntry?["type"] as? String, "remote")
    }

    t.test("宿主大配置：外来键语义保真（NSDictionary 相等）+ 同名拒绝 + 非对象容器中止") {
        let host = """
        {"oauthAccount": {"id": "u"}, "numStartups": 42,
         "projects": {"/a": {"allowedTools": ["Bash"]}},
         "mcpServers": {"idea": {"type": "http", "url": "https://x/mcp"}}}
        """
        let out = try MCPServerEditor.upsertJSON(
            into: host, definition: stdioDef, container: "mcpServers", style: .typed)
        let original = try MCPServerEditor.parse(host)
        var expected = original
        var servers = expected["mcpServers"] as? [String: Any] ?? [:]
        servers["context7"] = MCPServerEditor.encode(stdioDef, style: .typed)
        expected["mcpServers"] = servers
        let outRoot = try MCPServerEditor.parse(out)
        try expect(
            NSDictionary(dictionary: outRoot) == NSDictionary(dictionary: expected),
            "除新增 server 外全部键值必须语义保真")

        // 同名拒绝（不覆盖）
        do {
            _ = try MCPServerEditor.upsertJSON(
                into: out, definition: stdioDef, container: "mcpServers", style: .typed)
            try expect(false, "同名应抛 alreadyExists")
        } catch let error as MCPEditError {
            guard case .alreadyExists = error else {
                try expect(false, "错误类型不对：\(error)")
                return
            }
        }

        // 容器不是对象 → 中止不写
        do {
            _ = try MCPServerEditor.upsertJSON(
                into: #"{"mcpServers": []}"#, definition: stdioDef,
                container: "mcpServers", style: .typed)
            try expect(false, "非对象容器应抛 foreignConfig")
        } catch is InstallError {
            // 预期
        }
    }

    t.test("removeJSON：删净目标、保留容器与邻键；缺席抛 notFound") {
        let json = """
        {"mcpServers": {"a": {"command": "x"}, "b": {"command": "y"}}, "theme": "dark"}
        """
        let out = try MCPServerEditor.removeJSON(from: json, name: "a", container: "mcpServers")
        let root = try MCPServerEditor.parse(out)
        let servers = root["mcpServers"] as? [String: Any]
        try expect(servers?["a"] == nil)
        try expect(servers?["b"] != nil, "邻键不能被误删")
        try expectEqual(root["theme"] as? String, "dark")

        do {
            _ = try MCPServerEditor.removeJSON(from: out, name: "a", container: "mcpServers")
            try expect(false, "已删除的名字应抛 notFound")
        } catch let error as MCPEditError {
            guard case .notFound = error else {
                try expect(false, "错误类型不对：\(error)")
                return
            }
        }
    }

    // MARK: TOML 方言

    t.test("upsertTOML：EOF 追加段 + env 子段；notify/profiles/相邻 mcp_servers 不可破坏") {
        let toml = try fixtureString("configs/config-with-tables.toml")
        let out = try MCPServerEditor.upsertTOML(into: toml, definition: stdioDef)
        try expect(out.contains("[mcp_servers.context7]"))
        try expect(out.contains("command = \"npx\""))
        try expect(out.contains("args = [\"-y\", \"@upstash/context7-mcp\"]"))
        try expect(out.contains("[mcp_servers.context7.env]"))
        try expect(out.contains("CONTEXT7_API_KEY = \"fake-value\""))
        try expect(out.contains("[mcp_servers.notion]"), "相邻 mcp_servers 不能被破坏")
        try expect(out.contains("[mcp_servers.node_repl]"), "相邻 mcp_servers 不能被破坏")
        try expect(out.hasSuffix("\n"), "保持尾换行")
    }

    t.test("upsertTOML：同名拒绝；remote 拒绝（格式未实勘）；换行值拒绝") {
        let existing = "[mcp_servers.context7]\ncommand = \"old\"\n"
        do {
            _ = try MCPServerEditor.upsertTOML(into: existing, definition: stdioDef)
            try expect(false, "同名应抛 alreadyExists")
        } catch let error as MCPEditError {
            guard case .alreadyExists = error else {
                try expect(false, "错误类型不对：\(error)")
                return
            }
        }
        do {
            _ = try MCPServerEditor.upsertTOML(into: "", definition: remoteDef)
            try expect(false, "remote → TOML 应抛 unsupportedTarget")
        } catch let error as MCPEditError {
            guard case .unsupportedTarget = error else {
                try expect(false, "错误类型不对：\(error)")
                return
            }
        }
        var evil = stdioDef
        evil.env = ["BAD": "line1\nline2"]
        do {
            _ = try MCPServerEditor.upsertTOML(into: "", definition: evil)
            try expect(false, "含换行的值应拒绝")
        } catch let error as MCPEditError {
            guard case .invalidDefinition = error else {
                try expect(false, "错误类型不对：\(error)")
                return
            }
        }
    }

    t.test("removeTOML：连带清除 .env / .tools.* 子段，邻段无损") {
        let toml = """
        model = "gpt-5"
        notify = ["eureka-relay", "codex-notify"]

        [mcp_servers.notion]
        command = "npx"

        [mcp_servers.notion.tools.notion-update-page]
        enabled = false

        [mcp_servers.notion.env]
        NOTION_TOKEN = "fake"

        [mcp_servers.keep]
        command = "uvx"

        [profiles.fast]
        model = "gpt-5-mini"
        """
        let out = try MCPServerEditor.removeTOML(from: toml, name: "notion")
        try expect(!out.contains("notion"), "主段与全部子段必须删净")
        try expect(out.contains("[mcp_servers.keep]"), "邻段不能被误删")
        try expect(out.contains("[profiles.fast]"), "profiles 不能被破坏")
        try expect(out.contains("notify = "), "notify 不能被破坏")

        do {
            _ = try MCPServerEditor.removeTOML(from: out, name: "notion")
            try expect(false, "已删除的名字应抛 notFound")
        } catch let error as MCPEditError {
            guard case .notFound = error else {
                try expect(false, "错误类型不对：\(error)")
                return
            }
        }
    }

    // MARK: 跨方言 round-trip（传播的正确性核心）

    t.test("round-trip：JSON 读定义 → TOML 写 → TOML 读回，含 env 值逐字段一致") {
        let json = try MCPServerEditor.upsertJSON(
            into: "", definition: stdioDef, container: "mcpServers", style: .typed)
        let fromJSON = try MCPServerEditor.readDefinitionJSON(
            json, name: "context7", container: "mcpServers")
        let toml = try MCPServerEditor.upsertTOML(into: "", definition: fromJSON)
        let fromTOML = try MCPServerEditor.readDefinitionTOML(toml, name: "context7")
        try expectEqual(fromTOML.command, stdioDef.command)
        try expectEqual(fromTOML.args, stdioDef.args)
        try expectEqual(fromTOML.env, stdioDef.env, "env 值必须完整穿越两种方言")
        try expectEqual(fromTOML.transport, .stdio)
    }

    t.test("round-trip：opencode 的 command 数组读回 → plain 方言展开") {
        let opencode = try MCPServerEditor.upsertJSON(
            into: "", definition: stdioDef, container: "mcp", style: .opencode)
        let def = try MCPServerEditor.readDefinitionJSON(
            opencode, name: "context7", container: "mcp")
        try expectEqual(def.command, "npx", "数组首元素是可执行")
        try expectEqual(def.args, ["-y", "@upstash/context7-mcp"])
        try expectEqual(def.env["CONTEXT7_API_KEY"], "fake-value", "environment 键也要读到")
    }

    t.test("readDefinitionTOML：inline env 表与 .env 子段都要读到值") {
        let toml = """
        [mcp_servers.a]
        command = "npx"
        env = { INLINE_KEY = "inline-value" }

        [mcp_servers.a.env]
        SUB_KEY = "sub-value"
        """
        let def = try MCPServerEditor.readDefinitionTOML(toml, name: "a")
        try expectEqual(def.env["INLINE_KEY"], "inline-value")
        try expectEqual(def.env["SUB_KEY"], "sub-value")
    }

    // MARK: 编辑（update：合并式 / 原位改写）

    t.test("updateJSON：未建模键保留、enabled 不被翻转、置空的建模字段删除") {
        let json = """
        {"mcp": {"runner": {"type": "local", "command": ["bun", "x", "old"],
                            "environment": {"OLD_KEY": "old"},
                            "enabled": false, "customField": "keep-me"}},
         "provider": {"anthropic": {"apiKey": "keep"}}}
        """
        var edited = MCPServerDefinition(
            name: "runner", transport: .stdio, command: "npx", args: ["new-server"])
        edited.env = [:]  // 置空 environment
        let out = try MCPServerEditor.updateJSON(
            in: json, definition: edited, container: "mcp", style: .opencode)
        let entry = (try MCPServerEditor.parse(out)["mcp"]
            as? [String: Any])?["runner"] as? [String: Any]
        try expectEqual(entry?["enabled"] as? Bool, false, "编辑绝不翻转启停状态")
        try expectEqual(entry?["customField"] as? String, "keep-me", "未建模键必须保留")
        try expectEqual((entry?["command"] as? [String]) ?? [], ["npx", "new-server"])
        try expect(entry?["environment"] == nil, "置空的建模字段应删除")
        let provider = try MCPServerEditor.parse(out)["provider"] as? [String: Any]
        try expect(provider != nil, "配置其余部分不能丢")

        do {
            _ = try MCPServerEditor.updateJSON(
                in: json, definition: stdioDef, container: "mcp", style: .opencode)
            try expect(false, "编辑不存在的名字应抛 notFound")
        } catch let error as MCPEditError {
            guard case .notFound = error else {
                try expect(false, "错误类型不对：\(error)")
                return
            }
        }
    }

    t.test("updateJSON：stdio ↔ remote 切换时旧形态字段清干净") {
        let json = #"{"mcpServers": {"s": {"type": "stdio", "command": "npx", "args": ["a"]}}}"#
        let toRemote = MCPServerDefinition(
            name: "s", transport: .remote, url: "https://x/mcp")
        let out = try MCPServerEditor.updateJSON(
            in: json, definition: toRemote, container: "mcpServers", style: .typed)
        let entry = (try MCPServerEditor.parse(out)["mcpServers"]
            as? [String: Any])?["s"] as? [String: Any]
        try expectEqual(entry?["type"] as? String, "http")
        try expectEqual(entry?["url"] as? String, "https://x/mcp")
        try expect(entry?["command"] == nil, "切到 remote 后 command 应清掉")
        try expect(entry?["args"] == nil)
    }

    t.test("updateTOML：原位改写——.tools 子段、enabled、注释、段落顺序全部保留") {
        let toml = """
        [mcp_servers.notion]
        # 手写注释要活下来
        command = "npx"
        args = ["-y", "old-server"]
        enabled = false

        [mcp_servers.notion.tools.notion-update-page]
        enabled = false

        [mcp_servers.notion.env]
        NOTION_TOKEN = "old-token"

        [mcp_servers.keep]
        command = "uvx"
        """
        let edited = MCPServerDefinition(
            name: "notion", transport: .stdio,
            command: "bunx", args: ["new-server"], env: ["NOTION_TOKEN": "new-token"])
        let out = try MCPServerEditor.updateTOML(in: toml, definition: edited)
        try expect(out.contains("# 手写注释要活下来"), "注释必须保留")
        try expect(out.contains("enabled = false"), "enabled 必须保留")
        try expect(out.contains("command = \"bunx\""))
        try expect(out.contains("args = [\"new-server\"]"))
        try expect(out.contains("[mcp_servers.notion.tools.notion-update-page]"),
            ".tools 子段不能被动")
        try expect(out.contains("NOTION_TOKEN = \"new-token\""), "env 子段体应被重写")
        try expect(!out.contains("old-token"))
        try expect(out.contains("[mcp_servers.keep]"), "邻段无损")
        // 段落顺序未搬动：notion 主段仍在 keep 之前
        let notionPos = out.range(of: "[mcp_servers.notion]")!.lowerBound
        let keepPos = out.range(of: "[mcp_servers.keep]")!.lowerBound
        try expect(notionPos < keepPos, "原位改写不该搬动段落")
    }

    t.test("updateTOML：env 三形态——置空删子段；内联行重写；无 env 时补内联行") {
        // ① 置空 → 删除 .env 子段
        let withSub = """
        [mcp_servers.a]
        command = "npx"

        [mcp_servers.a.env]
        KEY = "v"
        """
        var cleared = MCPServerDefinition(name: "a", transport: .stdio, command: "npx")
        cleared.env = [:]
        let out1 = try MCPServerEditor.updateTOML(in: withSub, definition: cleared)
        try expect(!out1.contains(".env]"), "env 置空应删除子段")
        try expect(!out1.contains("KEY = "))

        // ② 内联 env 行重写
        let withInline = """
        [mcp_servers.b]
        command = "npx"
        env = { OLD = "1" }
        """
        let inlineEdit = MCPServerDefinition(
            name: "b", transport: .stdio, command: "npx", env: ["NEW": "2"])
        let out2 = try MCPServerEditor.updateTOML(in: withInline, definition: inlineEdit)
        try expect(out2.contains("env = { NEW = \"2\" }"))
        try expect(!out2.contains("OLD"))

        // ③ 原本无 env → 补内联行
        let bare = "[mcp_servers.c]\ncommand = \"npx\"\n"
        let addEnv = MCPServerDefinition(
            name: "c", transport: .stdio, command: "npx", env: ["K": "v"])
        let out3 = try MCPServerEditor.updateTOML(in: bare, definition: addEnv)
        try expect(out3.contains("env = { K = \"v\" }"))
    }

    t.test("updateTOML：已是 remote 的条目允许改 url（新建才限 stdio）") {
        let toml = """
        [mcp_servers.web]
        url = "https://old.example/mcp"
        """
        let edited = MCPServerDefinition(
            name: "web", transport: .remote, url: "https://new.example/mcp")
        let out = try MCPServerEditor.updateTOML(in: toml, definition: edited)
        try expect(out.contains("url = \"https://new.example/mcp\""))
        try expect(!out.contains("old.example"))
    }

    // MARK: 启停（enabled 键，实证 codex/grok TOML 与 opencode JSON 有此语义）

    t.test("setEnabledTOML：原位改写 enabled 行 / 缺失则补在段末；其余行不动") {
        let toml = """
        [mcp_servers.a]
        command = "npx"
        enabled = true

        [mcp_servers.b]
        command = "uvx"
        """
        let off = try MCPServerEditor.setEnabledTOML(in: toml, name: "a", enabled: false)
        try expect(off.contains("enabled = false"))
        try expect(!off.contains("enabled = true"))
        try expect(off.contains("command = \"npx\""), "其余键原样保留")

        let added = try MCPServerEditor.setEnabledTOML(in: toml, name: "b", enabled: false)
        try expect(added.contains("[mcp_servers.b]"))
        try expect(added.split(separator: "\n").contains("enabled = false"),
            "没有 enabled 键时应补写")
        try expect(added.contains("[mcp_servers.a]"), "邻段无损")

        do {
            _ = try MCPServerEditor.setEnabledTOML(in: toml, name: "missing", enabled: true)
            try expect(false, "不存在的名字应抛 notFound")
        } catch let error as MCPEditError {
            guard case .notFound = error else {
                try expect(false, "错误类型不对：\(error)")
                return
            }
        }
    }

    t.test("setEnabledJSON：只改 enabled，其余字段原样") {
        let json = """
        {"mcp": {"r": {"type": "remote", "url": "https://x", "enabled": true,
                       "headers": {"Authorization": "Bearer keep-me"}}}}
        """
        let out = try MCPServerEditor.setEnabledJSON(
            in: json, name: "r", container: "mcp", enabled: false)
        let entry = (try MCPServerEditor.parse(out)["mcp"]
            as? [String: Any])?["r"] as? [String: Any]
        try expectEqual(entry?["enabled"] as? Bool, false)
        try expectEqual(entry?["url"] as? String, "https://x")
        try expectEqual(
            (entry?["headers"] as? [String: String])?["Authorization"], "Bearer keep-me",
            "headers 原样保留")
    }

    // MARK: 粘贴解析

    t.test("parseQuickInput：命令 / URL / JSON 三形态与名称派生") {
        // npm 包（带版本后缀）
        let npx = MCPServerEditor.parseQuickInput("npx -y chrome-devtools-mcp@latest")
        try expectEqual(npx.count, 1)
        try expectEqual(npx[0].name, "chrome-devtools-mcp")
        try expectEqual(npx[0].command, "npx")
        try expectEqual(npx[0].args, ["-y", "chrome-devtools-mcp@latest"])
        try expectEqual(npx[0].transport, .stdio)

        // scoped npm 包
        let scoped = MCPServerEditor.parseQuickInput("npx -y @upstash/context7-mcp")
        try expectEqual(scoped.first?.name, "context7-mcp")

        // 非 npm：首个非 flag 参数（uvx 的包名不含 mcp 也要能派生）
        let uvx = MCPServerEditor.parseQuickInput("uvx code-review-graph serve")
        try expectEqual(uvx.first?.name, "code-review-graph")

        // URL：域名派生 + mcp. 前缀剥离
        let url = MCPServerEditor.parseQuickInput("https://mcp.notion.com/mcp")
        try expectEqual(url.first?.name, "notion")
        try expectEqual(url.first?.transport, .remote)
        try expectEqual(url.first?.url, "https://mcp.notion.com/mcp")
        try expectEqual(
            MCPServerEditor.parseQuickInput("https://example.com/mcp").first?.name, "example")

        // JSON 原样走 parsePasted
        let json = MCPServerEditor.parseQuickInput(
            #"{"mcpServers": {"a": {"command": "npx"}}}"#)
        try expectEqual(json.map(\.name), ["a"])

        try expectEqual(MCPServerEditor.parseQuickInput("   ").count, 0, "空输入返回空")
    }

    t.test("parsePasted：mcpServers 容器 / mcp 容器 / 顶层映射三种形态") {
        let full = #"{"mcpServers": {"a": {"command": "npx"}, "b": {"url": "https://x"}}}"#
        try expectEqual(MCPServerEditor.parsePasted(full).map(\.name), ["a", "b"])

        let opencode = #"{"mcp": {"c": {"type": "remote", "url": "https://y"}}}"#
        try expectEqual(MCPServerEditor.parsePasted(opencode).map(\.name), ["c"])

        let bare = #"{"d": {"command": "uvx", "args": ["mcp-server"]}}"#
        let bareDefs = MCPServerEditor.parsePasted(bare)
        try expectEqual(bareDefs.map(\.name), ["d"])
        try expectEqual(bareDefs.first?.args ?? [], ["mcp-server"])

        try expectEqual(MCPServerEditor.parsePasted("not json").count, 0, "坏 JSON 安静返回空")
        try expectEqual(
            MCPServerEditor.parsePasted(#"{"theme": "dark"}"#).count, 0,
            "无命令无地址的键不算 server")
    }
}
