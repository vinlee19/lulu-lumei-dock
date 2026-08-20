import EurekaIngest
import Foundation

func mcpProbeTests(_ t: TestRunner) {
    t.suite("MCPProbe（连接检测纯逻辑）")

    let validInit = """
    {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26",
     "capabilities":{"tools":{"listChanged":true},"prompts":{}},
     "serverInfo":{"name":"notion-mcp","version":"1.8.2"}}}
    """

    t.test("真握手：2xx + 合法 initialize 结果才算已连接") {
        let status = MCPProbe.classify(
            statusCode: 200, body: Data(validInit.utf8), contentType: "application/json")
        guard case .connected(let info) = status else {
            try expect(false, "应为 connected，得到 \(status)")
            return
        }
        try expectEqual(info.serverName, "notion-mcp")
        try expectEqual(info.serverVersion, "1.8.2")
        try expectEqual(info.protocolVersion, "2025-03-26")
        try expectEqual(info.capabilities, ["prompts", "tools"])
        try expect(info.summary.contains("v1.8.2"))
        try expect(info.summary.contains("协议 2025-03-26"))
    }

    t.test("误报修复：200 但响应不是 MCP → notMCP（旧实现会误判已连接）") {
        let html = Data("<html><body>hello</body></html>".utf8)
        try expectEqual(
            MCPProbe.classify(statusCode: 200, body: html, contentType: "text/html"),
            .notMCP)
        try expectEqual(
            MCPProbe.classify(statusCode: 200, body: nil, contentType: nil), .notMCP,
            "无响应体也不能算已连接")
        try expect(MCPProbe.Status.notMCP.hint != nil, "notMCP 要给检查 URL 的引导")
        try expectEqual(MCPProbe.Status.notMCP.tone, .warning)
    }

    t.test("SSE 载荷：text/event-stream 里取第一条 data: 行") {
        let sse = "event: message\ndata: \(validInit.replacingOccurrences(of: "\n", with: ""))\n\n"
        let status = MCPProbe.classify(
            statusCode: 200, body: Data(sse.utf8), contentType: "text/event-stream")
        guard case .connected(let info) = status else {
            try expect(false, "SSE 载荷应能解析出握手，得到 \(status)")
            return
        }
        try expectEqual(info.protocolVersion, "2025-03-26")
    }

    t.test("401 + WWW-Authenticate：解析 OAuth 元数据地址进引导") {
        let header = #"Bearer resource_metadata="https://mcp.notion.com/.well-known/oauth-protected-resource""#
        let status = MCPProbe.classify(statusCode: 401, wwwAuthenticate: header)
        guard case .unauthorized(let code, let authServer) = status else {
            try expect(false, "应为 unauthorized")
            return
        }
        try expectEqual(code, 401)
        try expectEqual(
            authServer, "https://mcp.notion.com/.well-known/oauth-protected-resource")
        try expect(status.hint?.contains("OAuth") == true, "有元数据时提示应点名 OAuth")

        // 无 header → 判定为 API key/请求头鉴权，引导编辑请求头（v2.7 分流）
        let plain = MCPProbe.classify(statusCode: 403)
        guard case .unauthorized(403, nil) = plain else {
            try expect(false, "应为 unauthorized(403, nil)")
            return
        }
        try expect(plain.hint?.contains("编辑请求头") == true, "无元数据 → 引导填密钥而非跳浏览器")
        try expect(plain.hint?.contains("/mcp") == true)
    }

    t.test("其余状态：httpError / tone 映射") {
        try expectEqual(MCPProbe.classify(statusCode: 404), .httpError(404))
        try expectEqual(MCPProbe.classify(statusCode: 500), .httpError(500))
        try expectEqual(MCPProbe.Status.commandFound("/bin/echo").tone, .ok)
        try expectEqual(MCPProbe.Status.unauthorized(code: 401, authServer: nil).tone, .warning)
        try expectEqual(MCPProbe.Status.httpError(500).tone, .bad)
        try expectEqual(MCPProbe.Status.unreachable("超时").tone, .bad)
        try expectEqual(MCPProbe.Status.commandMissing.tone, .bad)
    }

    t.test("parseToolsList：2025-11-25 富字段（title/注解/outputSchema）+ 分页游标 + SSE") {
        let json = """
        {"jsonrpc":"2.0","id":2,"result":{"tools":[
          {"name":"search","title":"全文检索","description":"搜索","inputSchema":{"type":"object"},
           "annotations":{"readOnlyHint":true,"destructiveHint":false}},
          {"name":"drop","outputSchema":{"type":"object"},
           "annotations":{"destructiveHint":true}},
          {"name":"fetch"}],"nextCursor":"page-2"}}
        """
        let page = MCPProbe.parseToolsList(Data(json.utf8), contentType: "application/json")
        try expectEqual(page?.tools.map(\.name), ["search", "drop", "fetch"])
        try expectEqual(page?.nextCursor, "page-2", "分页游标必须带出（否则大 server 被截断）")
        let search = page?.tools.first
        try expectEqual(search?.title, "全文检索")
        try expectEqual(search?.description, "搜索")
        try expectEqual(search?.readOnly, true)
        try expectEqual(search?.destructive, false)
        try expectEqual(search?.hasOutputSchema, false)
        let drop = page?.tools[1]
        try expectEqual(drop?.destructive, true)
        try expectEqual(drop?.hasOutputSchema, true)
        try expect(page?.tools.last?.readOnly == nil, "无注解时保持 nil，不猜")

        let sse = "data: \(json.replacingOccurrences(of: "\n", with: ""))\n\n"
        let sseTools = MCPProbe.parseToolsList(
            Data(sse.utf8), contentType: "text/event-stream")
        try expectEqual(sseTools?.tools.count, 3)

        try expect(MCPProbe.parseToolsList(
            Data("{}".utf8), contentType: "application/json") == nil)
        // 末页无 nextCursor
        let lastPage = MCPProbe.parseToolsList(
            Data(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#.utf8),
            contentType: "application/json")
        try expect(lastPage?.nextCursor == nil)
    }

    t.test("parseNamedList：resources/prompts 取名字+描述与游标（不读正文/URI）") {
        let json = """
        {"jsonrpc":"2.0","id":3,"result":{"resources":[
          {"uri":"file:///secret","name":"报表","description":"月度汇总"},
          {"name":"日志"}],"nextCursor":"r2"}}
        """
        let page = MCPProbe.parseNamedList(
            Data(json.utf8), contentType: "application/json", key: "resources")
        try expectEqual(page?.items.map(\.name), ["报表", "日志"])
        try expectEqual(page?.items.first?.description, "月度汇总")
        try expect(page?.items.last?.description == nil)
        try expectEqual(page?.nextCursor, "r2")
        try expect(MCPProbe.parseNamedList(
            Data(json.utf8), contentType: "application/json", key: "prompts") == nil,
            "键不存在 → nil（能力没声明就不该问）")
    }

    t.test("ToolInfo.params：inputSchema.properties 键名，必填带 *（不存 schema 正文）") {
        let json = """
        {"jsonrpc":"2.0","id":2,"result":{"tools":[
          {"name":"query","inputSchema":{"type":"object",
           "properties":{"sql":{"type":"string"},"limit":{"type":"number"}},
           "required":["sql"]}}]}}
        """
        let page = MCPProbe.parseToolsList(Data(json.utf8), contentType: "application/json")
        try expectEqual(page?.tools.first?.params, ["limit", "sql*"])
    }

    t.test("parseChallenge：scope 参数是权威 scope 来源（RFC 6750）") {
        let header = #"Bearer resource_metadata="https://s/.well-known/oauth-protected-resource", scope="files:read files:write""#
        let challenge = MCPProbe.parseChallenge(header)
        try expectEqual(
            challenge.resourceMetadata, "https://s/.well-known/oauth-protected-resource")
        try expectEqual(challenge.scopes, ["files:read", "files:write"])
        // 无 scope / 无 header 的空形态
        try expectEqual(MCPProbe.parseChallenge(#"Bearer realm="x""#).scopes, [])
        try expect(MCPProbe.parseChallenge(nil).resourceMetadata == nil)
    }

    t.test("MCPStdioProbe：mock server 全链路（握手/工具/参数/提示词/资源）") {
        let script = try fixtureURL("mock-mcp-stdio.sh").path
        let result = MCPStdioProbe.inspect(
            command: "/bin/sh", args: [script], env: [:], timeout: 10)
        guard case .success(let inspection) = result else {
            try expect(false, "应成功，得到 \(result)")
            return
        }
        try expectEqual(inspection.handshake.serverName, "mock")
        try expectEqual(inspection.handshake.protocolVersion, "2025-11-25")
        try expectEqual(inspection.tools.map(\.name), ["echo"])
        try expectEqual(inspection.tools.first?.description, "回显输入文本")
        try expectEqual(inspection.tools.first?.params, ["text*"])
        try expectEqual(inspection.prompts.map(\.name), ["review"])
        try expectEqual(inspection.prompts.first?.description, "评审提示")
        try expectEqual(inspection.resources.map(\.name), ["readme"])
        try expect(inspection.schemaTokens > 0, "schema 税按 tools/list 载荷估算")
    }

    t.test("MCPStdioProbe：失败面（命令缺失 / 非 MCP 输出 / 无响应超时）") {
        guard case .failure(.commandMissing) = MCPStdioProbe.inspect(
            command: "eureka-definitely-missing-cmd", args: [], env: [:], timeout: 2)
        else {
            try expect(false, "缺失命令应报 commandMissing")
            return
        }
        // /bin/cat 把 initialize 请求原样回显（有 id 但没有 result）→ 非法握手
        guard case .failure(.handshakeFailed) = MCPStdioProbe.inspect(
            command: "/bin/cat", args: [], env: [:], timeout: 5)
        else {
            try expect(false, "非 MCP 输出应报 handshakeFailed")
            return
        }
        // /bin/sleep 不读不答 → 在 deadline 内放弃（顺带验证进程被收尸，不留孤儿）
        guard case .failure(.handshakeFailed) = MCPStdioProbe.inspect(
            command: "/bin/sleep", args: ["30"], env: [:], timeout: 1)
        else {
            try expect(false, "无响应应在超时后报 handshakeFailed")
            return
        }
    }

    t.test("resolveCommand：绝对路径 / 注入 PATH / 空命令") {
        try expectEqual(MCPProbe.resolveCommand("/bin/echo"), "/bin/echo")
        try expect(MCPProbe.resolveCommand("/bin/definitely-not-a-command") == nil)
        try expectEqual(
            MCPProbe.resolveCommand("echo", pathVariable: "/nonexistent:/bin"), "/bin/echo")
        try expect(MCPProbe.resolveCommand("echo", pathVariable: "/nonexistent") == nil)
        try expect(MCPProbe.resolveCommand("", pathVariable: "/bin") == nil)
    }

    t.test("请求体：initialize 报 2025-11-25 / 通知无 id / list 带分页 cursor") {
        let initBody = try JSONSerialization.jsonObject(
            with: MCPProbe.initializeRequestBody()) as? [String: Any]
        try expectEqual(initBody?["method"] as? String, "initialize")
        try expectEqual(
            (initBody?["params"] as? [String: Any])?["protocolVersion"] as? String,
            "2025-11-25", "必须报最新定稿版本（server 自己会协商回落）")
        try expectEqual(MCPProbe.latestProtocolVersion, "2025-11-25")
        let notify = try JSONSerialization.jsonObject(
            with: MCPProbe.initializedNotificationBody()) as? [String: Any]
        try expectEqual(notify?["method"] as? String, "notifications/initialized")
        try expect(notify?["id"] == nil, "通知不能带 id")
        let list = try JSONSerialization.jsonObject(
            with: MCPProbe.toolsListRequestBody()) as? [String: Any]
        try expectEqual(list?["method"] as? String, "tools/list")
        try expect(list?["params"] == nil, "首页不带 params")
        let paged = try JSONSerialization.jsonObject(
            with: MCPProbe.toolsListRequestBody(cursor: "page-2")) as? [String: Any]
        try expectEqual(
            (paged?["params"] as? [String: Any])?["cursor"] as? String, "page-2")
        let resources = try JSONSerialization.jsonObject(
            with: MCPProbe.resourcesListRequestBody()) as? [String: Any]
        try expectEqual(resources?["method"] as? String, "resources/list")
        let prompts = try JSONSerialization.jsonObject(
            with: MCPProbe.promptsListRequestBody()) as? [String: Any]
        try expectEqual(prompts?["method"] as? String, "prompts/list")
    }

    t.test("MCPProbeSnapshot：Status 折算保真（标签/色调/摘要/引导）+ 缓存 round-trip") {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let connected = MCPProbeSnapshot(
            status: .connected(MCPProbe.HandshakeInfo(
                serverName: "notion-mcp", serverVersion: "1.8",
                protocolVersion: "2025-03-26", capabilities: ["tools"])),
            checkedAt: when)
        try expectEqual(connected.label, "已连接")
        try expectEqual(connected.tone, "ok")
        try expect(connected.detail?.contains("v1.8") == true, "握手摘要要进快照")

        let unauthorized = MCPProbeSnapshot(
            status: .unauthorized(code: 401, authServer: "https://as.example"),
            checkedAt: when)
        try expectEqual(unauthorized.tone, "warning")
        try expect(unauthorized.hint?.contains("OAuth") == true, "引导文案要进快照")

        let missing = MCPProbeSnapshot(status: .commandMissing, checkedAt: when)
        try expectEqual(missing.tone, "bad")
        let found = MCPProbeSnapshot(status: .commandFound("/bin/echo"), checkedAt: when)
        try expectEqual(found.detail, "/bin/echo")
        let unreachable = MCPProbeSnapshot(status: .unreachable("超时"), checkedAt: when)
        try expectEqual(unreachable.detail, "超时")

        // 落盘 round-trip（无密钥、无响应体——只有展示字段；authScheme 一并保真）
        let withScheme = MCPProbeSnapshot(
            status: .unauthorized(code: 401, authServer: "https://as.example"),
            authScheme: "oauth", checkedAt: when)
        try expectEqual(withScheme.authScheme, "oauth")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-probe-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        MCPProbeCache.upsert(key: "codex:/tmp/config.toml:notion", snapshot: withScheme, at: url)
        MCPProbeCache.upsert(key: "grok:/tmp/config.toml:notion", snapshot: found, at: url)
        let loaded = MCPProbeCache.load(from: url)
        try expectEqual(loaded.count, 2)
        try expectEqual(loaded["codex:/tmp/config.toml:notion"], withScheme)
        try expectEqual(
            loaded["codex:/tmp/config.toml:notion"]?.authScheme, "oauth",
            "鉴权方式折算必须持久化（重启后路由不丢）")
        try expectEqual(MCPProbeCache.load(from: FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).json")).count, 0)

        // v2.6 旧缓存（无 authScheme 键）必须照常解码
        let legacy = #"{"old": {"label":"已连接","tone":"ok","checkedAt":1700000000}}"#
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-probe-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: legacyURL) }
        try Data(legacy.utf8).write(to: legacyURL)
        let migrated = MCPProbeCache.load(from: legacyURL)
        try expectEqual(migrated["old"]?.label, "已连接")
        try expect(migrated["old"]?.authScheme == nil)
    }

    t.test("MCPToolCache：round-trip 与 upsert") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-mcp-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try expectEqual(MCPToolCache.load(from: url).count, 0, "缺失文件返回空表")

        let entry = MCPToolCacheEntry(
            toolCount: 2, toolNames: ["search", "fetch"], schemaTokens: 1234,
            serverVersion: "1.0", protocolVersion: "2025-11-25",
            capabilities: ["tools", "resources"],
            tools: [MCPToolSummary(
                name: "search", title: "全文检索", description: "搜索",
                readOnly: true, hasOutputSchema: true, params: ["query*", "limit"])],
            resourceCount: 7, promptCount: 1,
            prompts: [MCPNamedSummary(name: "review", description: "评审")],
            resources: [MCPNamedSummary(name: "readme")],
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000))
        MCPToolCache.upsert(name: "Notion", entry: entry, at: url)
        let loaded = MCPToolCache.load(from: url)
        try expectEqual(loaded["notion"], entry, "键按小写归一")
        try expectEqual(loaded["notion"]?.tools?.first?.title, "全文检索")
        try expectEqual(loaded["notion"]?.tools?.first?.params, ["query*", "limit"])
        try expectEqual(loaded["notion"]?.resourceCount, 7)
        try expectEqual(loaded["notion"]?.prompts?.first?.name, "review")
        try expectEqual(loaded["notion"]?.resources?.first?.name, "readme")
        // upsert 不影响其它键
        MCPToolCache.upsert(name: "other", entry: entry, at: url)
        try expectEqual(MCPToolCache.load(from: url).count, 2)

        // v2.4 旧缓存（无 tools/计数键）必须照常解码
        let legacy = """
        {"legacy": {"toolCount":1,"toolNames":["a"],"schemaTokens":10,
         "capabilities":[],"measuredAt":1700000000}}
        """
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-mcp-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: legacyURL) }
        try Data(legacy.utf8).write(to: legacyURL)
        let migrated = MCPToolCache.load(from: legacyURL)
        try expectEqual(migrated["legacy"]?.toolCount, 1)
        try expect(migrated["legacy"]?.tools == nil)
    }
}
