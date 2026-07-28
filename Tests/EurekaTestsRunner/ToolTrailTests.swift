import EurekaIngest
import Foundation

func toolTrailTests(_ t: TestRunner) {
    t.suite("ToolTrail")

    t.test("Claude 分类表：内置工具 kind/name/detail") {
        let read = ToolStepExtractor.claude(name: "Read", input: ["file_path": "/a/b.swift"])
        try expectEqual(read.kind, .read)
        try expectEqual(read.detail, "/a/b.swift")

        let glob = ToolStepExtractor.claude(name: "Glob", input: ["pattern": "**/*.swift"])
        try expectEqual(glob.kind, .search)
        try expectEqual(glob.detail, "**/*.swift")

        let grep = ToolStepExtractor.claude(
            name: "Grep", input: ["pattern": "validateToken", "path": "Sources"])
        try expectEqual(grep.kind, .search)
        try expectEqual(grep.detail, "validateToken in Sources")

        let web = ToolStepExtractor.claude(name: "WebSearch", input: ["query": "JWT expiry"])
        try expectEqual(web.kind, .web)
        try expectEqual(web.detail, "JWT expiry")

        let fetch = ToolStepExtractor.claude(name: "WebFetch", input: ["url": "https://x.dev"])
        try expectEqual(fetch.kind, .web)
        try expectEqual(fetch.detail, "https://x.dev")

        let bash = ToolStepExtractor.claude(
            name: "Bash", input: ["command": "swift test\ncd /tmp"])
        try expectEqual(bash.kind, .command)
        try expectEqual(bash.detail, "swift test …")  // 多行只取首行

        let edit = ToolStepExtractor.claude(
            name: "Edit", input: ["file_path": "/a/c.swift", "old_string": "x", "new_string": "y"])
        try expectEqual(edit.kind, .edit)
        try expectEqual(edit.detail, "/a/c.swift")

        let task = ToolStepExtractor.claude(
            name: "Task", input: ["subagent_type": "Explore", "description": "查找调用方"])
        try expectEqual(task.kind, .agent)
        try expectEqual(task.name, "Explore")
        try expectEqual(task.detail, "查找调用方")

        let skill = ToolStepExtractor.claude(name: "Skill", input: ["skill": "code-review"])
        try expectEqual(skill.kind, .skill)
        try expectEqual(skill.name, "code-review")

        let todo = ToolStepExtractor.claude(name: "TodoWrite", input: ["todos": ["x"]])
        try expectEqual(todo.kind, .other)
        try expectEqual(todo.name, "TodoWrite")
        try expectEqual(todo.detail, "")
    }

    // MARK: - Codex custom_tool_call（当前 Codex 的命令/补丁主通道）

    t.test("custom_tool_call exec：从 JS 源码里抽 cmd，含转义与多行") {
        // 形态照实勘：input 是 JS 源码而不是 JSON（12 个最大 rollout 里 exec 1334 条）
        let exec = ToolStepExtractor.codexCustomTool(name: "exec", input: """
        const r = await tools.exec_command({
          cmd: "wc -l /a/b.md && sed -n '1,240p' /a/c.md",
          yield_time_ms: 5000
        })
        """)
        try expectEqual(exec.kind, .command)
        try expectEqual(exec.name, "exec_command")
        try expectEqual(exec.detail, "wc -l /a/b.md && sed -n '1,240p' /a/c.md")

        // 转义序列要还原；命令类只取首行（ToolStep 口径）
        let escaped = ToolStepExtractor.codexCustomTool(
            name: "exec", input: #"await tools.exec_command({cmd: "echo \"hi\"\nls -la"})"#)
        try expectEqual(escaped.detail, #"echo "hi" …"#)

        // 相近 key 不能误命中（`foo_cmd:` 不是 `cmd:`）
        let nearMiss = ToolStepExtractor.codexCustomTool(
            name: "exec", input: #"await tools.exec_command({foo_cmd: "假的", cmd: "真的"})"#)
        try expectEqual(nearMiss.detail, "真的")
    }

    t.test("custom_tool_call：补丁三种落法都归 apply_patch/编辑") {
        let bare = ToolStepExtractor.codexCustomTool(name: "apply_patch", input: """
        *** Begin Patch
        *** Update File: /w/Sources/A.swift
        @@
        -old
        +new
        *** End Patch
        """)
        try expectEqual(bare.kind, .edit)
        try expectEqual(bare.name, "apply_patch")
        try expectEqual(bare.detail, "/w/Sources/A.swift")

        // exec 里塞裸补丁正文（实勘 97 条）
        let viaExec = ToolStepExtractor.codexCustomTool(name: "exec", input: """
        *** Begin Patch
        *** Add File: /w/Sources/B.swift
        *** End Patch
        """)
        try expectEqual(viaExec.kind, .edit)
        try expectEqual(viaExec.detail, "/w/Sources/B.swift")

        // exec 里 patch 变量（实勘 110 条）
        let viaVar = ToolStepExtractor.codexCustomTool(
            name: "exec",
            input: #"const patch = "*** Begin Patch\n*** Delete File: /w/C.swift\n*** End Patch";"#)
        try expectEqual(viaVar.kind, .edit)
        try expectEqual(viaVar.detail, "/w/C.swift")
    }

    t.test("custom_tool_call：tools.<名字> 归类与 function_call 通道口径一致") {
        let image = ToolStepExtractor.codexCustomTool(
            name: "exec", input: #"await tools.view_image({path: "/w/shot.png"})"#)
        try expectEqual(image.kind, .read)
        try expectEqual(image.name, "view_image")
        try expectEqual(image.detail, "/w/shot.png")

        let plan = ToolStepExtractor.codexCustomTool(
            name: "exec", input: "await tools.update_plan({plan: []})")
        try expectEqual(plan.kind, .other)
        try expectEqual(plan.detail, "更新计划")

        let mcp = ToolStepExtractor.codexCustomTool(
            name: "exec",
            input: #"await tools.mcp__claude_ai_Notion__notion_fetch({id: "abc"})"#)
        try expectEqual(mcp.kind, .mcp)
        try expectEqual(mcp.name, "Notion.notion_fetch", "清洗口径与 Claude 侧一致")

        let web = ToolStepExtractor.codexCustomTool(
            name: "exec", input: #"await tools.web__run({q: "swiftpm"})"#)
        try expectEqual(web.kind, .web)

        // 认不出的形态兜底当命令，保真不丢
        let unknown = ToolStepExtractor.codexCustomTool(name: "exec", input: "// 无法识别")
        try expectEqual(unknown.kind, .command)
        try expectEqual(unknown.detail, "// 无法识别")
    }

    t.test("Codex 工具结果：两代格式都判成败，判不出返回 nil") {
        // 老 rollout：结构化 exit_code（磁盘上还有近 1GB 这种文件，不能只认新格式）
        let legacyFail = AuditExtractor.codexOutcome(#"{"metadata":{"exit_code":1}}"#)
        try expectEqual(legacyFail?.isError, true)
        try expectEqual(legacyFail?.exitCode, 1)
        try expectEqual(AuditExtractor.codexOutcome(#"{"metadata":{"exit_code":0}}"#)?.isError, false)

        // 当前 Codex：metadata 已消失，只能看输出文本
        let failed: [[String: Any]] = [["type": "input_text", "text": "Script failed\nWall time 0.9 seconds"]]
        try expectEqual(AuditExtractor.codexOutcome(failed)?.isError, true)
        let ok: [[String: Any]] = [["type": "input_text", "text": "Script completed\nWall time 0.1 seconds"]]
        try expectEqual(AuditExtractor.codexOutcome(ok)?.isError, false)
        try expectEqual(AuditExtractor.codexOutcome("Exit code: 2\nOutput:\n")?.exitCode, 2)
        try expectEqual(AuditExtractor.codexOutcome("Exit code: 0\n")?.isError, false)

        // 判不出就说不知道，别假装成功（否则失败步会被静默标成正常）
        try expect(AuditExtractor.codexOutcome("Plan updated") == nil)
        try expect(AuditExtractor.codexOutcome(nil) == nil)
    }

    t.test("Claude MCP 命名清洗：mcp__server__tool → server.tool，去 claude_ai_ 前缀") {
        let mcp = ToolStepExtractor.claude(
            name: "mcp__claude_ai_Notion__notion-search", input: ["query": "设计文档"])
        try expectEqual(mcp.kind, .mcp)
        try expectEqual(mcp.name, "Notion.notion-search")
        try expectEqual(mcp.detail, "设计文档")
    }

    t.test("Claude 缺 input 容错：detail 空、不崩") {
        let step = ToolStepExtractor.claude(name: "Read", input: nil)
        try expectEqual(step.kind, .read)
        try expectEqual(step.detail, "")
    }

    t.test("Codex 命令三代形态：exec_command / shell_command / shell 数组") {
        let exec = ToolStepExtractor.codex(
            name: "exec_command", argumentsJSON: #"{"cmd":"make test","workdir":"/w"}"#)
        try expectEqual(exec.kind, .command)
        try expectEqual(exec.detail, "make test")

        let shellCmd = ToolStepExtractor.codex(
            name: "shell_command", argumentsJSON: #"{"command":"ls -la"}"#)
        try expectEqual(shellCmd.kind, .command)
        try expectEqual(shellCmd.detail, "ls -la")

        let shell = ToolStepExtractor.codex(
            name: "shell", argumentsJSON: #"{"command":["bash","-lc","git status"]}"#)
        try expectEqual(shell.kind, .command)
        try expectEqual(shell.detail, "git status")  // 去 bash -lc 头

        let shellNoWrap = ToolStepExtractor.codex(
            name: "shell", argumentsJSON: #"{"command":["ls","-la"]}"#)
        try expectEqual(shellNoWrap.detail, "ls -la")
    }

    t.test("Codex apply_patch 提取文件路径 / view_image / update_plan / 未知名兜底") {
        let patch = ToolStepExtractor.codex(
            name: "apply_patch",
            argumentsJSON: """
            {"input":"*** Begin Patch\\n*** Update File: Sources/A.swift\\n+x\\n*** Add File: B.md\\n*** End Patch"}
            """)
        try expectEqual(patch.kind, .edit)
        try expectEqual(patch.detail, "Sources/A.swift, B.md")

        let img = ToolStepExtractor.codex(
            name: "view_image", argumentsJSON: #"{"path":"/tmp/shot.png"}"#)
        try expectEqual(img.kind, .read)
        try expectEqual(img.detail, "/tmp/shot.png")

        let plan = ToolStepExtractor.codex(name: "update_plan", argumentsJSON: "{}")
        try expectEqual(plan.kind, .other)
        try expectEqual(plan.detail, "更新计划")

        let unknown = ToolStepExtractor.codex(
            name: "future_tool", argumentsJSON: #"{"target":"x"}"#)
        try expectEqual(unknown.kind, .other)
        try expectEqual(unknown.detail, "x")
    }

    t.test("Codex 坏 JSON arguments 容错：detail 空、不崩") {
        let step = ToolStepExtractor.codex(name: "exec_command", argumentsJSON: "{not json")
        try expectEqual(step.kind, .command)
        try expectEqual(step.detail, "")
        let nilArgs = ToolStepExtractor.codex(name: "exec_command", argumentsJSON: nil)
        try expectEqual(nilArgs.detail, "")
    }

    t.test("detail 超长截断（≤160 + 省略号）") {
        let long = String(repeating: "a", count: 500)
        let step = ToolStepExtractor.claude(name: "Read", input: ["file_path": long])
        try expectEqual(step.detail.count, 161)  // 160 + "…"
        try expect(step.detail.hasSuffix("…"))
    }

    t.test("plainText：步数标题 + 逐步 label/name/失败标记/detail") {
        let text = ToolStepExtractor.plainText([
            ToolStep(kind: .read, name: "Read", detail: "/a/b.swift"),
            ToolStep(kind: .command, name: "Bash", detail: "swift test", isError: true),
        ])
        try expect(text.contains("本轮轨迹（2 步）"))
        try expect(text.contains("[读取] Read /a/b.swift"))
        try expect(text.contains("[命令] Bash（失败） swift test"))
    }

    t.test("Claude 切轮：trail 在首个 tool_use 位、每轮一条、sidechain 跳过、错误回填") {
        let path = try fixtureURL("claude-transcript-trail.jsonl").path
        let result = TranscriptReader.loadClaude(path: path, maxMessages: 2000)
        try expect(!result.truncated)
        let roles = result.messages.map(\.role)
        try expectEqual(roles, [.user, .assistant, .turnTrail, .assistant, .user, .turnTrail])
        try expect(!roles.contains(.toolNote), "Claude 不应再产出 toolNote")

        // 轮 1：7 步（sidechain 的 Read 不计入）
        let trail1 = result.messages[2]
        try expectEqual(trail1.steps.count, 7)
        try expectEqual(trail1.steps[0].kind, .read)
        try expectEqual(trail1.steps[0].detail, "/w/Sources/Auth/Login.swift")
        try expectEqual(trail1.steps[1].kind, .search)
        try expectEqual(trail1.steps[1].detail, "validateToken in Sources")
        try expectEqual(trail1.steps[2].kind, .command)
        try expectEqual(trail1.steps[2].name, "Bash")
        try expect(trail1.steps[2].isError, "tool_result is_error 应回填到 Bash 步")
        try expect(!trail1.steps[0].isError)
        try expectEqual(trail1.steps[3].kind, .edit)
        try expectEqual(trail1.steps[4].kind, .mcp)
        try expectEqual(trail1.steps[4].name, "Notion.notion-search")
        try expectEqual(trail1.steps[5].kind, .agent)
        try expectEqual(trail1.steps[5].name, "Explore")
        try expectEqual(trail1.steps[6].kind, .skill)
        try expectEqual(trail1.steps[6].name, "code-review")
        // text 含步骤明文（会话内搜索可命中）
        try expect(trail1.text.contains("本轮轨迹（7 步）"))
        try expect(trail1.text.contains("/w/Sources/Auth/Login.swift"))

        // 轮 2：独立 trail
        let trail2 = result.messages[5]
        try expectEqual(trail2.steps.count, 1)
        try expectEqual(trail2.steps[0].detail, "/w/Sources/Auth/Register.swift")
    }

    t.test("Claude 截断：步数计入 maxMessages 预算") {
        let path = try fixtureURL("claude-transcript-trail.jsonl").path
        let result = TranscriptReader.loadClaude(path: path, maxMessages: 4)
        try expect(result.truncated)
        // user + assistant(text) + trail(1 步) 后预算耗尽
        try expectEqual(result.messages.count, 3)
        try expectEqual(result.messages[2].role, .turnTrail)
        try expectEqual(result.messages[2].steps.count, 1)
        try expect(result.messages[2].text.contains("本轮轨迹（1 步）"), "截断后 trail 文本仍应回填")
    }

    t.test("Codex 切轮：function_call/web_search/mcp 成步、_ 前缀跳过、exit_code 与 Err 回填") {
        let path = try fixtureURL("codex-rollout-trail.jsonl").path
        let result = TranscriptReader.loadCodex(path: path, maxMessages: 2000)
        try expect(!result.truncated)
        let roles = result.messages.map(\.role)
        try expectEqual(roles, [.user, .turnTrail, .assistant, .user, .turnTrail])

        let trail1 = result.messages[1]
        try expectEqual(trail1.steps.count, 3, "_ 前缀 MCP 重复项应跳过")
        try expectEqual(trail1.steps[0].kind, .command)
        try expectEqual(trail1.steps[0].name, "exec_command")
        try expectEqual(trail1.steps[0].detail, "ls -la")
        try expect(trail1.steps[0].isError, "function_call_output exit_code=1 应回填")
        try expectEqual(trail1.steps[1].kind, .mcp)
        try expectEqual(trail1.steps[1].name, "context7.query-docs")
        try expectEqual(trail1.steps[1].detail, "swiftpm resources")
        try expect(trail1.steps[1].isError, "mcp result.Err 应置失败")
        try expectEqual(trail1.steps[2].kind, .web)
        try expectEqual(trail1.steps[2].detail, "SwiftPM resources copy")

        let trail2 = result.messages[4]
        try expectEqual(trail2.steps.count, 1)
        try expectEqual(trail2.steps[0].detail, "swift test")  // shell 数组去 bash -lc 头
    }
}
