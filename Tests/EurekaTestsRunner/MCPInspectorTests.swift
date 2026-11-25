import EurekaIngest
import Foundation

/// Scripted channel: answers each method from a table, records what was asked
private final class FakeChannel: MCPInspectorChannel {
    typealias Handler = (MCPInspector.Request) -> Result<MCPInspector.Reply, MCPInspector.ChannelFailure>
    var handlers: [String: Handler] = [:]
    private(set) var sent: [MCPInspector.Request] = []
    var legacyTransportAvailable = false
    private(set) var switchedToLegacyTransport = false

    func send(
        _ request: MCPInspector.Request
    ) -> Result<MCPInspector.Reply, MCPInspector.ChannelFailure> {
        sent.append(request)
        guard let handler = handlers[request.method] else {
            return .success(json(#"{"jsonrpc":"2.0","id":0,"error":{"code":-32601,"message":"Method not found"}}"#))
        }
        return handler(request)
    }

    func fallBackToLegacyTransport() -> Bool {
        guard legacyTransportAvailable, !switchedToLegacyTransport else { return false }
        switchedToLegacyTransport = true
        return true
    }

    var methods: [String] { sent.map(\.method) }
}

private func json(_ text: String, status: Int? = nil) -> MCPInspector.Reply {
    MCPInspector.Reply(data: Data(text.utf8), contentType: "application/json", statusCode: status)
}

private func meta(_ request: MCPInspector.Request) -> [String: Any]? {
    let root = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
    return (root?["params"] as? [String: Any])?["_meta"] as? [String: Any]
}

func mcpInspectorTests(_ t: TestRunner) {
    t.suite("MCPInspector（跨协议版本探测）")

    let legacyInit = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"legacy","title":"Legacy Server","version":"3"},"instructions":"Does legacy things."}}"#
    let oneTool = #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search","inputSchema":{"type":"object","properties":{"q":{"type":"string","description":"query"},"n":{"type":["integer","null"]}},"required":["q"]}}]}}"#
    let discoverResult = #"{"jsonrpc":"2.0","id":10,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{},"prompts":{}},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"modern","version":"9"}},"instructions":"Modern server."}}"#

    t.test("握手时代：discover 被拒（任意错误码）→ 回退 initialize，随后带协商版本头") {
        let channel = FakeChannel()
        channel.handlers["initialize"] = { _ in .success(json(legacyInit, status: 200)) }
        channel.handlers["notifications/initialized"] = { _ in .success(json("", status: 202)) }
        channel.handlers["tools/list"] = { _ in .success(json(oneTool, status: 200)) }
        guard case .inspected(let inspection) = MCPInspector.inspect(channel) else {
            try expect(false, "应成功")
            return
        }
        try expectEqual(
            channel.methods,
            ["server/discover", "initialize", "notifications/initialized", "tools/list"])
        try expectEqual(inspection.handshake.protocolVersion, "2025-06-18")
        try expectEqual(inspection.handshake.serverTitle, "Legacy Server")
        try expectEqual(inspection.handshake.instructions, "Does legacy things.")
        try expectEqual(inspection.tools.map(\.name), ["search"])
        try expect(inspection.toolsError == nil)
        // initialize offers the newest handshake revision, never the stateless one
        let initBody = try JSONSerialization.jsonObject(with: channel.sent[1].body) as? [String: Any]
        try expectEqual(
            (initBody?["params"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        try expect(channel.sent[1].protocolVersion == nil, "握手请求本身不带版本头")
        // Follow-ups carry the negotiated version and no modern metadata
        let list = channel.sent[3]
        try expectEqual(list.protocolVersion, "2025-06-18")
        try expect(!list.modern)
        try expect(meta(list) == nil, "握手时代的请求不带 _meta")
    }

    t.test("新版（无状态）：discover 成功即连通，不握手；每个请求带 _meta 与版本") {
        let channel = FakeChannel()
        channel.handlers["server/discover"] = { _ in .success(json(discoverResult, status: 200)) }
        channel.handlers["tools/list"] = { _ in .success(json(oneTool, status: 200)) }
        channel.handlers["prompts/list"] = { _ in
            .success(json(#"{"jsonrpc":"2.0","id":4,"result":{"resultType":"complete","prompts":[{"name":"p"}]}}"#, status: 200))
        }
        guard case .inspected(let inspection) = MCPInspector.inspect(channel) else {
            try expect(false, "应成功")
            return
        }
        try expectEqual(channel.methods, ["server/discover", "tools/list", "prompts/list"])
        try expectEqual(inspection.handshake.serverName, "modern")
        try expectEqual(inspection.handshake.protocolVersion, "2026-07-28")
        try expectEqual(inspection.handshake.instructions, "Modern server.")
        try expectEqual(inspection.prompts.map(\.name), ["p"])
        for request in channel.sent {
            try expect(request.modern)
            try expectEqual(request.protocolVersion, "2026-07-28")
            let m = meta(request)
            try expectEqual(
                m?["io.modelcontextprotocol/protocolVersion"] as? String, "2026-07-28")
            try expect(m?["io.modelcontextprotocol/clientCapabilities"] != nil, "必填字段")
        }
    }

    t.test("新版 server 要求别的版本：按 supported 重试 discover，绝不回退握手") {
        let channel = FakeChannel()
        channel.handlers["server/discover"] = { request in
            let version = meta(request)?["io.modelcontextprotocol/protocolVersion"] as? String
            if version == "2027-01-15" {
                return .success(json(#"{"jsonrpc":"2.0","id":10,"result":{"supportedVersions":["2027-01-15"],"capabilities":{}}}"#, status: 200))
            }
            return .success(json(#"{"jsonrpc":"2.0","id":10,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2027-01-15"],"requested":"2026-07-28"}}}"#, status: 400))
        }
        guard case .inspected(let inspection) = MCPInspector.inspect(channel) else {
            try expect(false, "应成功")
            return
        }
        try expectEqual(inspection.handshake.protocolVersion, "2027-01-15")
        try expect(!channel.methods.contains("initialize"), "可识别的新版错误不得回退 initialize")
    }

    t.test("只支持新版的 server 先被问到 initialize：错误里点名版本 → 改用 discover") {
        let channel = FakeChannel()
        var discoverCalls = 0
        channel.handlers["server/discover"] = { _ in
            discoverCalls += 1
            // The first probe is lost (a slow start on stdio); the retry is answered
            return discoverCalls == 1 ? .failure(.timedOut)
                : .success(json(discoverResult))
        }
        channel.handlers["initialize"] = { _ in
            .success(json(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"no initialize","data":{"supported":["2026-07-28"]}}}"#))
        }
        channel.handlers["tools/list"] = { _ in .success(json(oneTool)) }
        guard case .inspected(let inspection) = MCPInspector.inspect(channel) else {
            try expect(false, "应成功")
            return
        }
        try expectEqual(inspection.handshake.serverName, "modern")
        try expectEqual(
            Array(channel.methods.prefix(3)), ["server/discover", "initialize", "server/discover"])
    }

    t.test("握手时代 server 拒绝版本而非协商回落：按 supported 换旧版重试 initialize") {
        let channel = FakeChannel()
        channel.handlers["initialize"] = { request in
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            let version = (body?["params"] as? [String: Any])?["protocolVersion"] as? String
            if version == "2024-11-05" {
                return .success(json(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"old","version":"0"}}}"#))
            }
            return .success(json(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Unsupported protocol version","data":{"supported":["2024-11-05"],"requested":"2025-11-25"}}}"#))
        }
        channel.handlers["tools/list"] = { _ in .success(json(oneTool)) }
        guard case .inspected(let inspection) = MCPInspector.inspect(channel) else {
            try expect(false, "应成功")
            return
        }
        try expectEqual(inspection.handshake.protocolVersion, "2024-11-05")
        try expect(inspection.handshake.instructions == nil, "2024-11-05 没有 instructions，不算错")
        try expect(inspection.tools.first?.readOnly == nil, "旧版没有注解，不算错")
    }

    t.test("HTTP：initialize 被 404/405 拒绝 → 回退旧版 HTTP+SSE 传输后重发") {
        let channel = FakeChannel()
        channel.legacyTransportAvailable = true
        channel.handlers["server/discover"] = { _ in .success(json("Not Found", status: 404)) }
        channel.handlers["initialize"] = { [unowned channel] _ in
            channel.switchedToLegacyTransport
                ? .success(json(legacyInit, status: 200))
                : .success(json("Method Not Allowed", status: 405))
        }
        channel.handlers["tools/list"] = { _ in .success(json(oneTool, status: 200)) }
        guard case .inspected = MCPInspector.inspect(channel) else {
            try expect(false, "应成功")
            return
        }
        try expect(channel.switchedToLegacyTransport)

        // No legacy transport either → the real HTTP status is reported
        let dead = FakeChannel()
        dead.handlers["server/discover"] = { _ in .success(json("", status: 404)) }
        dead.handlers["initialize"] = { _ in .success(json("", status: 404)) }
        try expectEqual(MCPInspector.inspect(dead), .failed(.httpError(404)))
    }

    t.test("失败面：401 带元数据 / 200 非 MCP / 不可达 / 握手超时") {
        let unauthorized = FakeChannel()
        unauthorized.handlers["server/discover"] = { _ in
            .success(MCPInspector.Reply(
                data: Data(), statusCode: 401,
                wwwAuthenticate: #"Bearer resource_metadata="https://as.example/meta""#))
        }
        try expectEqual(
            MCPInspector.inspect(unauthorized),
            .failed(.unauthorized(code: 401, authServer: "https://as.example/meta")))
        try expectEqual(unauthorized.methods, ["server/discover"], "401 与协议时代无关，不再试握手")

        let website = FakeChannel()
        website.handlers["server/discover"] = { _ in .success(json("<html>", status: 200)) }
        website.handlers["initialize"] = { _ in .success(json("<html>", status: 200)) }
        try expectEqual(MCPInspector.inspect(website), .failed(.notMCP))

        let offline = FakeChannel()
        offline.handlers["server/discover"] = { _ in .failure(.transport("offline")) }
        try expectEqual(MCPInspector.inspect(offline), .failed(.unreachable("offline")))

        let mute = FakeChannel()
        mute.handlers["server/discover"] = { _ in .failure(.timedOut) }
        mute.handlers["initialize"] = { _ in .failure(.timedOut) }
        guard case .failed(.unreachable) = MCPInspector.inspect(mute) else {
            try expect(false, "两种开场都没回应 → 不可达")
            return
        }
    }

    t.test("已连接但 tools/list 失败：toolsError 说明原因，不伪装成「没有工具」") {
        let channel = FakeChannel()
        channel.handlers["initialize"] = { _ in .success(json(legacyInit)) }
        channel.handlers["tools/list"] = { _ in
            .success(json(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"backend down"}}"#))
        }
        guard case .inspected(let inspection) = MCPInspector.inspect(channel) else {
            try expect(false, "握手成功应算已连接")
            return
        }
        try expectEqual(inspection.toolsError, "backend down")
        try expectEqual(inspection.tools.count, 0)

        // The cache keeps the previous good list and records why it is stale
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = MCPToolCacheEntry(
            toolCount: 1, toolNames: ["search"], schemaTokens: 50,
            tools: [MCPToolSummary(name: "search")], measuredAt: now.addingTimeInterval(-3600))
        let merged = MCPToolCacheEntry(inspection: inspection, previous: previous, now: now)
        try expectEqual(merged.toolNames, ["search"], "刷新失败不能抹掉上次的好结果")
        try expectEqual(merged.toolsError, "backend down")
        try expectEqual(merged.instructions, "Does legacy things.")
        try expectEqual(merged.measuredAt, now)
        let fresh = MCPToolCacheEntry(inspection: inspection, previous: nil, now: now)
        try expectEqual(fresh.toolCount, 0)
        try expectEqual(fresh.toolsError, "backend down")

        // input_required (2026-07-28 multi round-trip) cannot be answered by a probe
        let asking = FakeChannel()
        asking.handlers["server/discover"] = { _ in .success(json(discoverResult)) }
        asking.handlers["tools/list"] = { _ in
            .success(json(#"{"jsonrpc":"2.0","id":2,"result":{"resultType":"input_required"}}"#))
        }
        guard case .inspected(let blocked) = MCPInspector.inspect(asking) else {
            try expect(false, "应算已连接")
            return
        }
        try expect(blocked.toolsError != nil)
    }

    t.test("分页与缓存条目：跟随 nextCursor；参数带类型与描述；介绍与描述有上限") {
        let channel = FakeChannel()
        channel.handlers["initialize"] = { _ in .success(json(legacyInit)) }
        channel.handlers["tools/list"] = { request in
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            let cursor = (body?["params"] as? [String: Any])?["cursor"] as? String
            if cursor == "p2" {
                return .success(json(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"b","description":"\#(String(repeating: "x", count: 3000))"}]}}"#))
            }
            return .success(json(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search","inputSchema":{"type":"object","properties":{"q":{"type":"string","description":"query"},"n":{"type":["integer","null"]}},"required":["q"]}}],"nextCursor":"p2"}}"#))
        }
        guard case .inspected(var inspection) = MCPInspector.inspect(channel) else {
            try expect(false, "应成功")
            return
        }
        try expectEqual(inspection.tools.map(\.name), ["search", "b"])
        try expect(inspection.schemaTokens > 0)
        inspection.handshake.instructions = String(repeating: "介", count: 6000)
        let entry = MCPToolCacheEntry(inspection: inspection, previous: nil, now: Date())
        try expectEqual(entry.tools?[0].params, ["n", "q*"])
        try expectEqual(entry.tools?[0].paramDetails, [
            MCPToolParamSummary(name: "n", type: "integer | null", required: false),
            MCPToolParamSummary(name: "q", type: "string", required: true, description: "query"),
        ])
        try expectEqual(entry.tools?[1].description?.count, 2000)
        try expect((entry.instructions?.utf8.count ?? 0) <= MCPToolCacheEntry.instructionsLimit + 3)
        try expect(entry.instructions?.hasSuffix("…") == true)
        try expectEqual(entry.serverTitle, "Legacy Server")
        try expectEqual(entry.serverName, "legacy")
    }

    t.test("SSE 解析：跨块、CRLF、多行 data、注释、未以空行收尾") {
        var parser = MCPSSEParser()
        var events = parser.feed(Data(": ping\r\nevent: endpoint\r\ndata: /messages?session=1\r\n\r\nda".utf8))
        try expectEqual(events, [MCPSSEParser.Event(name: "endpoint", data: "/messages?session=1")])
        events = parser.feed(Data("ta: {\"a\":\ndata: 1}\n\ndata: tail".utf8))
        try expectEqual(events, [MCPSSEParser.Event(name: "message", data: "{\"a\":\n1}")])
        try expectEqual(parser.finish(), [MCPSSEParser.Event(name: "message", data: "tail")])

        // Streamable HTTP answer preceded by a server notification on the same stream
        let stream = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\"}\n\n"
            + "event: message\ndata: \(legacyInit)\n\n"
        let info = MCPProbe.parseInitializeResponse(
            Data(stream.utf8), contentType: "text/event-stream")
        try expectEqual(info?.serverName, "legacy", "要取带 result 的那条，而不是第一条 data")
        // 2025-03-26 batch body
        let batch = "[{\"jsonrpc\":\"2.0\",\"method\":\"notifications/x\"},\(legacyInit)]"
        try expectEqual(
            MCPProbe.parseInitializeResponse(Data(batch.utf8), contentType: "application/json")?
                .protocolVersion, "2025-06-18")
    }

    t.test("stdio 全链路：新版无状态 mock（discover + 带 _meta 的 tools/list）") {
        let script = try fixtureURL("mock-mcp-stdio-modern.sh").path
        let result = MCPStdioProbe.inspect(
            command: "/bin/sh", args: [script], env: [:], timeout: 10)
        guard case .success(let inspection) = result else {
            try expect(false, "应成功，得到 \(result)")
            return
        }
        try expectEqual(inspection.handshake.serverName, "modern-mock")
        try expectEqual(inspection.handshake.protocolVersion, "2026-07-28")
        try expectEqual(inspection.handshake.instructions, "Weather utilities.")
        try expectEqual(inspection.tools.map(\.name), ["get_weather"])
        try expect(inspection.toolsError == nil)
    }

    t.test("stdio：握手前不作声的旧 server → discover 超时后回退；tools/list 失败如实上报") {
        let script = try fixtureURL("mock-mcp-stdio-silent.sh").path
        let report = MCPStdioProbe.inspectDetailed(
            command: "/bin/sh", args: [script], env: [:], timeout: 10, discoverTimeout: 0.4)
        guard case .success(let inspection) = report.result else {
            try expect(false, "应成功，得到 \(report.result)")
            return
        }
        try expectEqual(inspection.handshake.protocolVersion, "2024-11-05")
        try expectEqual(inspection.toolsError, "backend unavailable")
    }

    t.test("stdio：收到未知请求就退出的旧 server → 重启一次直接握手；stderr 尾部可供诊断") {
        let script = try fixtureURL("mock-mcp-stdio-strict.sh").path
        let report = MCPStdioProbe.inspectDetailed(
            command: "/bin/sh", args: [script], env: [:], timeout: 10)
        guard case .success(let inspection) = report.result else {
            try expect(false, "应成功，得到 \(report.result)")
            return
        }
        try expectEqual(inspection.handshake.serverName, "strict")
        try expectEqual(inspection.tools.map(\.name), ["only"])

        // A command that fails outright: the reason on stderr is handed back
        let broken = MCPStdioProbe.inspectDetailed(
            command: "/bin/sh", args: ["-c", "echo 'missing API key' >&2; exit 3"], env: [:],
            timeout: 5)
        guard case .failure(.handshakeFailed) = broken.result else {
            try expect(false, "应失败")
            return
        }
        try expectEqual(broken.stderrTail, "missing API key")
    }

    t.test("stdio 环境：命令按传入 PATH 解析；相对路径按工作目录解析；env 覆盖在上") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-mcp-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("server.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try expect(MCPProbe.resolveCommand("./server.sh", pathVariable: "") == nil
            || FileManager.default.currentDirectoryPath == dir.path)
        try expectEqual(
            MCPProbe.resolveCommand("./server.sh", pathVariable: "", workingDirectory: dir),
            tool.standardizedFileURL.path)
        // GUI-style bare PATH cannot see the tool; the login PATH can
        try expect(MCPProbe.resolveCommand("server.sh", pathVariable: "/usr/bin:/bin") == nil)
        let login = LoginShellEnvironment(
            base: ["PATH": "/usr/bin:/bin", "HOME": "/tmp"], probe: { "\(dir.path):/usr/bin" })
        let env = login.environment()
        try expectEqual(env["PATH"], "\(dir.path):/usr/bin:/bin", "登录 PATH 在前、去重、保留自身独有项")
        try expectEqual(env["HOME"], "/tmp", "只取 PATH，其余环境不变")
        try expectEqual(
            MCPProbe.resolveCommand("server.sh", pathVariable: env["PATH"] ?? ""), tool.path)
        // Shell startup noise around the value is ignored
        try expectEqual(
            LoginShellEnvironment.parse("motd\n__EUREKA_PATH_START__/a:/b__EUREKA_PATH_END__\n%"),
            "/a:/b")
        try expect(LoginShellEnvironment.parse("no markers /a:/b") == nil)
        let unavailable = LoginShellEnvironment(base: ["PATH": "/bin"], probe: { nil })
        try expectEqual(unavailable.environment()["PATH"], "/bin", "取不到登录 PATH 时退回自身")
    }
}
