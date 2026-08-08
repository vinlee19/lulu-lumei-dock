import EurekaIngest
import EurekaInstall
import EurekaKit
import EurekaSync
import Foundation

/// Trae ingest 测试。fixture 按本机真实数据的字节形状伪造（Trae CN 3.3.84 /
/// 国际版 3.5.35），路径与 session id 全换假值；全程临时目录，不碰真实 ~/。
///
/// 覆盖三条与别的源不同的要点：
///   1. **两个渠道**（`~/.trae-cn` CN 与 `~/.trae` 国际版）是两个独立应用，同一个来源；
///   2. 会话库是 SQLCipher 加密的 → 会话只能从明文记忆库 `topics.md` 反推；
///   3. 记忆库项目目录名多一个 `--p<N>-<hash>` 后缀，且**不可反解**。
func traeIngestTests(_ t: TestRunner) {
    traePathsTests(t)
    traeHooksInstallerTests(t)
    traeHookDecoderTests(t)
    traeSessionIndexerTests(t)
    traeKnowledgeTests(t)
    traePlanTests(t)
    traeSyncWhitelistTests(t)
}

// MARK: - TraeHooksInstaller（~/.trae-cn/hooks.json）

/// 假想的"他人已占用"骨架：同 `~/.codex/hooks.json` 被 Otty 占用那种情形。
/// Trae 的 hooks.json 与 Claude/Codex 同构，所以共存是首要测点。
private let traeForeignOccupied = """
{
  "hooks": {
    "UserPromptSubmit": [
      { "_other": true, "hooks": [{ "command": "'/Applications/Other.app/hook.sh' submit", "type": "command" }] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "command": "/usr/local/bin/other-guard", "type": "command" }] }
    ]
  }
}
"""

private func traeHooksInstallerTests(_ t: TestRunner) {
    t.suite("TraeHooksInstaller · hooks.json")

    let relay = "/Users/me/Library/Application Support/Eureka/bin/eureka-relay"

    func hooks(of json: String) throws -> [String: Any] {
        let root = try expectSome(
            (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])
        return try expectSome(root["hooks"] as? [String: Any])
    }

    t.test("空文件安装：6 个事件都装上；命令是 trae-hook 且路径带引号") {
        let updated = try TraeHooksInstaller.install(into: "", relayPath: relay)
        let map = try hooks(of: updated)
        try expectEqual(
            Set(map.keys), Set(TraeHooksInstaller.managedEvents),
            "实得 \(map.keys.sorted())")
        // Trae 没有 SessionEnd / Notification（→ 等待授权对它永远不可见），别凭空写进去
        try expect(!map.keys.contains("SessionEnd"))
        try expect(!map.keys.contains("Notification"))
        // Trae 独有的 PostCompact 要在
        try expect(map.keys.contains("PostCompact"))

        let command = try expectSome(
            (map["Stop"] as? [[String: Any]])?
                .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .compactMap { $0["command"] as? String }.first)
        try expectEqual(
            command, "\"\(relay)\" trae-hook",
            "载荷自带 hook_event_name → 不像 Codex 那样把事件名带在命令行上")
    }

    t.test("matcher 只给工具类事件；非工具事件不写这个键") {
        let map = try hooks(of: try TraeHooksInstaller.install(into: "", relayPath: relay))
        for event in ["PreToolUse", "PostToolUse"] {
            let ours = try expectSome((map[event] as? [[String: Any]])?.first {
                ($0["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.contains("eureka-relay") == true
                }
            })
            try expectEqual(ours["matcher"] as? String, "*", "\(event) 应带 matcher")
        }
        for event in ["UserPromptSubmit", "Stop", "PreCompact", "PostCompact"] {
            let ours = try expectSome((map[event] as? [[String: Any]])?.first)
            try expect(ours["matcher"] == nil, "\(event) 不该写它可能不认的 matcher")
        }
    }

    t.test("装进被他人占用的文件：别人的条目一条不少") {
        let updated = try TraeHooksInstaller.install(into: traeForeignOccupied, relayPath: relay)
        let map = try hooks(of: updated)

        let submit = try expectSome(map["UserPromptSubmit"] as? [[String: Any]])
        try expectEqual(submit.filter { $0["_other"] as? Bool == true }.count, 1, "他人条目被弄丢了")
        let preTool = try expectSome(map["PreToolUse"] as? [[String: Any]])
        try expectEqual(
            preTool.filter { $0["matcher"] as? String == "Bash" }.count, 1,
            "他人的 matcher: Bash 条目必须逐字保留")
        for event in TraeHooksInstaller.managedEvents {
            let entries = try expectSome(map[event] as? [[String: Any]])
            let ours = entries.filter { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.contains("eureka-relay") == true
                }
            }
            try expectEqual(ours.count, 1, "\(event) 应恰好有我们一条")
        }
    }

    t.test("重装替换自己的旧条目而不叠加；卸载只摘自己的") {
        let old = try TraeHooksInstaller.install(
            into: traeForeignOccupied, relayPath: "/old/path/eureka-relay")
        let again = try TraeHooksInstaller.install(into: old, relayPath: "/new/path/eureka-relay")
        let map = try hooks(of: again)
        let stop = try expectSome(map["Stop"] as? [[String: Any]])
        try expectEqual(stop.count, 1, "重装不该叠加成两条")
        try expect(
            (stop[0]["hooks"] as? [[String: Any]] ?? [])
                .compactMap { $0["command"] as? String }
                .allSatisfy { $0.contains("/new/path/") },
            "重装应把路径换成新的")

        let removed = try TraeHooksInstaller.uninstall(from: again)
        let after = try hooks(of: removed)
        try expect(
            !TraeHooksInstaller.foreignHooks(in: removed).events.isEmpty,
            "他人条目应还在")
        try expectEqual(
            after.filter { key, _ in
                ((after[key] as? [[String: Any]]) ?? []).contains { entry in
                    (entry["hooks"] as? [[String: Any]] ?? []).contains {
                        ($0["command"] as? String)?.contains("eureka-relay") == true
                    }
                }
            }.count,
            0, "卸载后不该留下任何我们的条目")
        try expect(after["UserPromptSubmit"] != nil, "他人占用的事件键不能被顺手删掉")
        try expect(after["Stop"] == nil, "只有我们一条的事件，摘空后该把键删掉")
    }

    t.test("认不出的结构一律拒写，绝不覆盖看不懂的内容") {
        // 事件值不是数组
        let weird = #"{"hooks": {"Stop": {"command": "something"}}}"#
        var threw = false
        do { _ = try TraeHooksInstaller.install(into: weird, relayPath: relay) } catch { threw = true }
        try expect(threw, "事件值不是条目数组时必须抛错而不是当空数组覆盖")
        // 整个文件不是 JSON 对象
        threw = false
        do { _ = try TraeHooksInstaller.install(into: "not json", relayPath: relay) } catch {
            threw = true
        }
        try expect(threw)
        // 卸载路径同样要拒
        threw = false
        do { _ = try TraeHooksInstaller.uninstall(from: weird) } catch { threw = true }
        try expect(threw)
    }

    t.test("状态与诊断：装全 / 装一半 / 路径漂移 / relay 不见了") {
        try expectEqual(TraeHooksInstaller.status(of: ""), .none)
        let full = try TraeHooksInstaller.install(into: "", relayPath: relay)
        try expectEqual(TraeHooksInstaller.status(of: full), .installed)
        // 摘掉一个事件 → partial
        var map = try hooks(of: full)
        map.removeValue(forKey: "PostCompact")
        let partialJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: ["hooks": map]), as: UTF8.self)
        try expectEqual(TraeHooksInstaller.status(of: partialJSON), .partial)

        try expectEqual(
            TraeHooksInstaller.diagnose(
                json: full, expectedRelayPath: relay, relayIsExecutable: { _ in true }),
            .installed)
        // 路径被手改
        guard case .driftedPath = TraeHooksInstaller.diagnose(
            json: full, expectedRelayPath: "/other/eureka-relay",
            relayIsExecutable: { _ in true })
        else { throw ExpectationError(description: "路径不一致应报 driftedPath") }
        // relay 不可执行
        guard case .relayMissing = TraeHooksInstaller.diagnose(
            json: full, expectedRelayPath: relay, relayIsExecutable: { _ in false })
        else { throw ExpectationError(description: "relay 不可执行应报 relayMissing") }
        // 缺事件
        guard case .stale(let missing) = TraeHooksInstaller.diagnose(
            json: partialJSON, expectedRelayPath: relay, relayIsExecutable: { _ in true })
        else { throw ExpectationError(description: "缺事件应报 stale") }
        try expectEqual(missing, ["PostCompact"])
        // 坏 JSON
        guard case .unparseable = TraeHooksInstaller.diagnose(
            json: "not json", expectedRelayPath: relay, relayIsExecutable: { _ in true })
        else { throw ExpectationError(description: "坏 JSON 应报 unparseable") }
        // 没装
        try expectEqual(
            TraeHooksInstaller.diagnose(
                json: "{}", expectedRelayPath: relay, relayIsExecutable: { _ in true }),
            .notInstalled)
    }
}

// MARK: - TraePaths

private func traePathsTests(_ t: TestRunner) {
    t.suite("TraePaths")

    t.test("configHome：EUREKA_TRAE_HOME / EUREKA_TRAE_INTL_HOME 覆盖，否则 ~/.trae-cn 与 ~/.trae") {
        let env = [
            "EUREKA_TRAE_HOME": "/tmp/tr-cn",
            "EUREKA_TRAE_INTL_HOME": "/tmp/tr-intl",
        ]
        try expectEqual(TraePaths.configHome(.cn, environment: env).path, "/tmp/tr-cn")
        try expectEqual(TraePaths.configHome(.intl, environment: env).path, "/tmp/tr-intl")
        try expect(TraePaths.configHome(.cn, environment: [:]).path.hasSuffix("/.trae-cn"))
        try expect(TraePaths.configHome(.intl, environment: [:]).path.hasSuffix("/.trae"))
        // 国际版目录名是 CN 的前缀，别把 `.trae-cn` 当成 `.trae`
        try expect(!TraePaths.configHome(.cn, environment: [:]).path.hasSuffix("/.trae"))
    }

    t.test("appSupportHome 取 product.json 的 nameShort：Trae CN / Trae") {
        try expect(
            TraePaths.appSupportHome(.cn, environment: [:]).path
                .hasSuffix("Library/Application Support/Trae CN"))
        try expect(
            TraePaths.appSupportHome(.intl, environment: [:]).path
                .hasSuffix("Library/Application Support/Trae"))
        try expectEqual(
            TraePaths.appSupportHome(.cn, environment: ["EUREKA_TRAE_APP_SUPPORT": "/tmp/as"]).path,
            "/tmp/as")
    }

    t.test("派生根：hooks / skills / builtin ×2 / memory / user_rules / workspaceStorage") {
        let env = ["EUREKA_TRAE_HOME": "/tmp/tr-cn", "EUREKA_TRAE_APP_SUPPORT": "/tmp/as"]
        try expectEqual(TraePaths.hooksConfig(environment: env).path, "/tmp/tr-cn/hooks.json")
        try expectEqual(TraePaths.skillsRoot(.cn, environment: env).path, "/tmp/tr-cn/skills")
        try expectEqual(
            TraePaths.builtinSkillsRoot(.cn, environment: env).path, "/tmp/tr-cn/builtin_skills")
        try expectEqual(
            TraePaths.builtinGlobalSkillsRoot(.cn, environment: env).path,
            "/tmp/tr-cn/builtin/global/skills")
        try expectEqual(TraePaths.memoryRoot(environment: env).path, "/tmp/tr-cn/memory")
        try expectEqual(
            TraePaths.userProfileFile(environment: env).path, "/tmp/tr-cn/memory/user_profile.md")
        try expectEqual(
            TraePaths.memoryProjectsRoot(environment: env).path, "/tmp/tr-cn/memory/projects")
        try expectEqual(
            TraePaths.userRulesFile(.cn, environment: env).path, "/tmp/tr-cn/user_rules.md")
        try expectEqual(TraePaths.userRulesDir(.cn, environment: env).path, "/tmp/tr-cn/user_rules")
        try expectEqual(
            TraePaths.workspaceStorageRoot(.cn, environment: env).path,
            "/tmp/as/User/workspaceStorage")
        // 项目级
        let repo = URL(fileURLWithPath: "/work/proj", isDirectory: true)
        try expectEqual(
            TraePaths.projectSkillsRoot(repoRoot: repo).path, "/work/proj/.trae/skills")
        try expectEqual(
            TraePaths.projectRulesRoot(repoRoot: repo).path, "/work/proj/.trae/rules")
        try expectEqual(
            TraePaths.projectDocumentsRoot(repoRoot: repo).path, "/work/proj/.trae/documents")
        try expectEqual(
            TraePaths.projectHooksConfig(repoRoot: repo).path, "/work/proj/.trae/hooks.json")
    }

    t.test("installedChannels：按目录是否存在判定；env 覆盖过的渠道无条件算装了") {
        let base = try makeTraeTemp()
        defer { try? FileManager.default.removeItem(at: base) }
        let cn = base.appendingPathComponent("cn", isDirectory: true)
        let intl = base.appendingPathComponent("intl", isDirectory: true)

        // env 覆盖 → 即使目录还没建也算装了（测试全靠临时目录，不能被存在性过滤掉）
        try expect(!FileManager.default.fileExists(atPath: cn.path), "刻意不建目录")
        try expectEqual(
            TraePaths.installedChannels(environment: [
                "EUREKA_TRAE_HOME": cn.path, "EUREKA_TRAE_INTL_HOME": intl.path,
            ]),
            [.cn, .intl], "CN 必须排在前（功能更全的那个）")
        // 存在性判定分支只能拿真实 home 试，而测试不许碰真实 ~/ → 这里不断言，
        // 改为断言"没被 env 覆盖的渠道走的是真实目录判定"这个可观察的等价事实。
        let intlOnly = TraePaths.installedChannels(
            environment: ["EUREKA_TRAE_INTL_HOME": intl.path])
        try expect(intlOnly.contains(.intl), "被 env 覆盖的渠道必然在内")

        // 聚合派生：两个渠道各一个可写技能根 + 每渠道两个只读 builtin 根
        let env = ["EUREKA_TRAE_HOME": cn.path, "EUREKA_TRAE_INTL_HOME": intl.path]
        try expectEqual(TraePaths.userSkillsRoots(environment: env).count, 2)
        try expectEqual(
            TraePaths.bundledSkillsRoots(environment: env).count, 4,
            "builtin_skills 与 builtin/global/skills 内容不同，两处都得扫")
    }

    t.test("cliCommand：CN 是 trae-cn、国际版是 trae") {
        try expectEqual(TraePaths.Channel.cn.cliCommand, "trae-cn")
        try expectEqual(TraePaths.Channel.intl.cliCommand, "trae")
    }
}

// MARK: - hook 解码（复用 ClaudeHookDecoder，只换 source）

private func traeHookDecoderTests(_ t: TestRunner) {
    t.suite("Trae hooks 解码")

    func decode(_ payload: [String: Any]) -> TaskEvent? {
        ClaudeHookDecoder.decode(payload: payload, receivedAt: Date(), source: .trae)
    }

    t.test("UserPromptSubmit → taskStarted，source 是 trae 而不是 claude") {
        let event = try expectSome(decode([
            "hook_event_name": "UserPromptSubmit", "session_id": "6a75a6cd",
            "cwd": "/work/proj", "prompt": "分析一下这个项目",
        ]))
        try expectEqual(event.source, .trae)
        try expectEqual(event.sessionId, "6a75a6cd")
        try expectEqual(event.cwd, "/work/proj")
        guard case .taskStarted(let title) = event.kind else {
            throw ExpectationError(description: "应是 taskStarted，实得 \(event.kind)")
        }
        try expectEqual(title, "分析一下这个项目")
    }

    t.test("Stop → taskFinished(success)；PreCompact → compacting") {
        let stop = try expectSome(decode(["hook_event_name": "Stop", "session_id": "s1"]))
        guard case .taskFinished(let outcome, _, _) = stop.kind else {
            throw ExpectationError(description: "应是 taskFinished，实得 \(stop.kind)")
        }
        try expectEqual(outcome, .success)

        let compact = try expectSome(decode(["hook_event_name": "PreCompact", "session_id": "s1"]))
        try expectEqual(compact.kind, .compacting)
    }

    t.test("PostCompact（Trae 独有）→ 无工具名心跳，让 TaskStore 复位 isCompacting") {
        let event = try expectSome(decode(["hook_event_name": "PostCompact", "session_id": "s1"]))
        try expectEqual(event.kind, .activity(tool: nil))

        // 端到端：compacting 之后来一条 PostCompact，卡片不该继续显示"压缩中"
        var store = TaskStore()
        _ = store.apply(TaskEvent(
            source: .trae, sessionId: "s1", kind: .taskStarted(title: "t"), timestamp: Date()))
        _ = store.apply(TaskEvent(
            source: .trae, sessionId: "s1", kind: .compacting, timestamp: Date()))
        try expectEqual(store.activeTasks.first?.value.isCompacting, true)
        _ = store.apply(TaskEvent(
            source: .trae, sessionId: "s1", kind: .activity(tool: nil), timestamp: Date()))
        try expectEqual(store.activeTasks.first?.value.isCompacting, false)
    }

    t.test("PreToolUse → toolPending 且 detail 走 ToolStepExtractor；PostToolUse → activity") {
        let pending = try expectSome(decode([
            "hook_event_name": "PreToolUse", "session_id": "s1",
            "tool_name": "Bash", "tool_input": ["command": "ls -la\n还有第二行"],
        ]))
        guard case .toolPending(let tool, let detail) = pending.kind else {
            throw ExpectationError(description: "应是 toolPending，实得 \(pending.kind)")
        }
        try expectEqual(tool, "Bash")
        try expectEqual(detail, "ls -la …", "命令类工具只取首行，后面还有内容时补省略号")

        let post = try expectSome(decode([
            "hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Read",
        ]))
        try expectEqual(post.kind, .activity(tool: "Read"))
    }

    t.test("防御：缺 session_id / 未知事件 / Trae 没有的 Notification 都返回 nil 而不是崩") {
        try expect(decode(["hook_event_name": "UserPromptSubmit"]) == nil, "缺 session_id")
        try expect(decode(["session_id": "s1"]) == nil, "缺事件名")
        try expect(decode(["hook_event_name": "FutureEvent", "session_id": "s1"]) == nil)
        // Trae 二进制里没有 Notification 这个 hook，但真来了也得能宽松吃下
        try expect(
            decode([
                "hook_event_name": "Notification", "session_id": "s1",
                "notification_type": "auth_success",
            ]) == nil,
            "与等待无关的通知类型不构成事件")
    }

    t.test("trae-hook 通道接进 EventRouter，且信封 terminal 会贴上") {
        let envelope: [String: Any] = [
            "channel": "trae-hook",
            "receivedAtMs": Date().timeIntervalSince1970 * 1000,
            "terminal": ["app": "Trae CN", "bundleId": "com.trae.cn"],
            "payload": [
                "hook_event_name": "UserPromptSubmit", "session_id": "s9", "prompt": "hi",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let raw = try expectSome(RawEvent(data: data))
        let events = EventRouter.route(raw)
        try expectEqual(events.count, 1)
        try expectEqual(events.first?.source, .trae)
        try expectEqual(events.first?.terminal?.app, "Trae CN")
    }

    t.test("审计旁路：PostToolUse 出 AuditEvent，opId 前缀带 source 不与 Claude 撞键") {
        let payload: [String: Any] = [
            "hook_event_name": "PostToolUse", "session_id": "s1",
            "tool_name": "Bash", "tool_input": ["command": "rm -rf /tmp/x"],
        ]
        let fixed = Date(timeIntervalSince1970: 1_786_095_893)
        let trae = try expectSome(
            ClaudeAuditDecoder.decode(payload: payload, receivedAt: fixed, source: .trae))
        let claude = try expectSome(
            ClaudeAuditDecoder.decode(payload: payload, receivedAt: fixed, source: .claude))
        try expectEqual(trae.source, .trae)
        try expect(trae.opId.hasPrefix("trae:"))
        try expect(claude.opId.hasPrefix("claude:"))
        try expect(trae.opId != claude.opId, "同载荷不同来源必须是不同的 opId")
    }
}

// MARK: - TraeSessionIndexer（从明文记忆库反推会话）

private func traeSessionIndexerTests(_ t: TestRunner) {
    t.suite("TraeSessionIndexer")

    t.test("topics.md：单行无换行的 [头]正文 能解析出 id / 时间 / 摘要") {
        let base = try makeTraeTemp()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("topics.md")
        // 实勘：整个文件就是一行，末尾没有换行
        try Data(
            #"[session_id: 6a75a6cd602f315c19ec63ac | topic_summary_time: 2026-08-07 17:51:40]User requested an analysis of the LeRobot project. The user then asked for a deeper analysis."#
                .utf8
        ).write(to: file)

        let topics = TraeSessionIndexer.parseTopics(fileURL: file)
        try expectEqual(topics.count, 1)
        try expectEqual(topics.first?.sessionId, "6a75a6cd602f315c19ec63ac")
        try expect(
            topics.first?.summary.hasPrefix("User requested an analysis") == true,
            "正文应从块头之后起算，实得 \(topics.first?.summary ?? "<nil>")")
        try expect(topics.first?.summaryTime != nil, "topic_summary_time 应解析成功")
    }

    t.test("topics.md：两个块紧邻不换行时也要正确定界（不能把下一块头吞进上一块正文）") {
        let base = try makeTraeTemp()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("topics.md")
        try Data(
            ("[session_id: aaa | topic_summary_time: 2026-08-07 10:00:00]第一段摘要"
                + "[session_id: bbb | topic_summary_time: 2026-08-07 11:00:00]第二段摘要").utf8
        ).write(to: file)

        let topics = TraeSessionIndexer.parseTopics(fileURL: file)
        try expectEqual(topics.map(\.sessionId), ["aaa", "bbb"])
        try expectEqual(topics.first?.summary, "第一段摘要")
        try expectEqual(topics.last?.summary, "第二段摘要")
    }

    t.test("防御：文件不存在 / 空文件 / 没有块头 → 空数组，不崩") {
        let base = try makeTraeTemp()
        defer { try? FileManager.default.removeItem(at: base) }
        try expectEqual(
            TraeSessionIndexer.parseTopics(
                fileURL: base.appendingPathComponent("nope.md")).count, 0)
        let empty = base.appendingPathComponent("empty.md")
        try Data().write(to: empty)
        try expectEqual(TraeSessionIndexer.parseTopics(fileURL: empty).count, 0)
        let plain = base.appendingPathComponent("plain.md")
        try Data("就是一段普通 markdown".utf8).write(to: plain)
        try expectEqual(TraeSessionIndexer.parseTopics(fileURL: plain).count, 0)
    }

    t.test("stripProjectSuffix：剥 --p<N>-<hash>；没有该形态原样返回；--p 后非数字不算后缀") {
        try expectEqual(
            TraeSessionIndexer.stripProjectSuffix(
                "-Users-me-work-lerobot--p2-832ae42141a2828b9304"),
            "-Users-me-work-lerobot")
        try expectEqual(
            TraeSessionIndexer.stripProjectSuffix("-Users-me-work-lerobot"),
            "-Users-me-work-lerobot")
        try expectEqual(
            TraeSessionIndexer.stripProjectSuffix("-Users-me-my--project"),
            "-Users-me-my--project", "`--p` 后不是数字就不是后缀")
    }

    t.test("cwd 反查：正向编码已知 workspace folder 去比对，绝不反着切 `-`") {
        // `aftership-semantic-layer` 这种名字反着 split 会只剩 `layer`（CLAUDE.md 记着的坑）
        let cwd = "/Users/me/work/aftership-semantic-layer"
        let encoded = SkillMemoryIndexer.encodeProjectDirName(cwd)
        try expectEqual(
            TraeSessionIndexer.resolveCwd(
                encodedDirName: encoded + "--p2-abc123", knownCwds: [cwd]),
            cwd)
        // 无后缀形态也要认
        try expectEqual(
            TraeSessionIndexer.resolveCwd(encodedDirName: encoded, knownCwds: [cwd]), cwd)
        // 比不中就返回 nil —— 宁可不显示 cwd 也不显示一个错的
        try expect(
            TraeSessionIndexer.resolveCwd(
                encodedDirName: "-Users-me-work-other--p1-x", knownCwds: [cwd]) == nil)
        // 前缀相同但不是同一个项目：`…-lerobot` 不该匹配上 `…-lerobot-sub`
        let sub = "/Users/me/work/lerobot-sub"
        try expect(
            TraeSessionIndexer.resolveCwd(
                encodedDirName: SkillMemoryIndexer.encodeProjectDirName(sub) + "--p1-y",
                knownCwds: ["/Users/me/work/lerobot"]) == nil)
    }

    t.test("index：合并 topics.md 与 session_memory jsonl 的时间，跨日目录归到同一会话") {
        let base = try makeTraeTemp()
        defer { try? FileManager.default.removeItem(at: base) }
        let cwd = "/Users/me/work/lerobot"
        let fixture = try TraeMemoryFixture(base: base, cwd: cwd)
        // 两天的目录，同一个 session：证明必须跨目录合并而不是各出一条
        try fixture.addDay(
            "20260806", sessionId: "sess1", summary: "第一天：初步分析",
            summaryTime: "2026-08-06 10:00:00", turnMillis: [1_786_009_200_000])
        try fixture.addDay(
            "20260807", sessionId: "sess1", summary: "第二天：深入架构分析",
            summaryTime: "2026-08-07 17:51:40", turnMillis: [1_786_097_697_737])

        let sessions = TraeSessionIndexer.index(
            memoryProjectsRoot: fixture.projectsRoot,
            workspaceStorageRoots: [fixture.workspaceStorageRoot],
            window: .greatestFiniteMagnitude,
            now: Date(timeIntervalSince1970: 1_786_100_000))
        try expectEqual(sessions.count, 1, "同一 session 跨两个日目录只应出一条")
        let session = try expectSome(sessions.first)
        try expectEqual(session.source, .trae)
        try expectEqual(session.id, "sess1")
        try expectEqual(session.cwd, cwd)
        try expectEqual(session.name, "第二天：深入架构分析", "较新的日目录摘要应覆盖较早的")
        try expectEqual(session.sizeBytes, 0, "共享库的源不报单会话体积")
        try expect(
            session.transcriptPath.hasSuffix("topics.md"),
            "transcriptPath 应指向明文来源，绝不能是那个加密库")
        let started = try expectSome(session.startedAt)
        try expect(started < session.lastActiveAt, "startedAt 取最早、lastActiveAt 取最晚")
    }

    t.test("index：window 过滤按 lastActiveAt；recentDirectories 去重返回 cwd") {
        let base = try makeTraeTemp()
        defer { try? FileManager.default.removeItem(at: base) }
        let cwd = "/Users/me/work/lerobot"
        let fixture = try TraeMemoryFixture(base: base, cwd: cwd)
        try fixture.addDay(
            "20260807", sessionId: "fresh", summary: "新的",
            summaryTime: "2026-08-07 17:00:00", turnMillis: [1_786_100_000_000])
        try fixture.addDay(
            "20250101", sessionId: "ancient", summary: "很久以前",
            summaryTime: "2025-01-01 09:00:00", turnMillis: [1_735_689_600_000])

        let now = Date(timeIntervalSince1970: 1_786_100_500)
        let recent = TraeSessionIndexer.index(
            memoryProjectsRoot: fixture.projectsRoot,
            workspaceStorageRoots: [fixture.workspaceStorageRoot],
            window: 30 * 86400, now: now)
        try expectEqual(recent.map(\.id), ["fresh"], "超出窗口的会话不该出现")

        let dirs = TraeSessionIndexer.recentDirectories(
            memoryProjectsRoot: fixture.projectsRoot,
            workspaceStorageRoots: [fixture.workspaceStorageRoot],
            window: .greatestFiniteMagnitude, now: now)
        try expectEqual(dirs, [cwd], "同一 cwd 只出现一次")
    }

    t.test("根不存在时返回空，且不去读真实 ~/") {
        let base = try makeTraeTemp()
        defer { try? FileManager.default.removeItem(at: base) }
        try expectEqual(
            TraeSessionIndexer.index(
                memoryProjectsRoot: base.appendingPathComponent("nope", isDirectory: true),
                workspaceStorageRoots: [base.appendingPathComponent("nope2", isDirectory: true)],
                window: .greatestFiniteMagnitude).count,
            0)
    }
}

// MARK: - 知识面：技能 / 记忆 vs 指令的硬分割

private func traeKnowledgeTests(_ t: TestRunner) {
    t.suite("Trae 知识面")

    t.test("技能：两个渠道各自的 skills 都收，且 .eureka-disabled 里的算停用") {
        let base = try makeTraeTemp()
        defer { try? FileManager.default.removeItem(at: base) }
        let cn = base.appendingPathComponent("cn/skills", isDirectory: true)
        let intl = base.appendingPathComponent("intl/skills", isDirectory: true)
        try plantSkill(root: cn, name: "byted-web-search", description: "豆包搜索")
        try plantSkill(root: intl, name: "arkcli-auth", description: "ARK 认证")
        try plantSkill(
            root: base.appendingPathComponent("cn/skills.eureka-disabled", isDirectory: true),
            name: "off-skill", description: "停用的")

        let skills = SkillMemoryIndexer.indexSkills(
            claudeSkillsRoot: base.appendingPathComponent("empty-claude", isDirectory: true),
            codexSkillsRoot: base.appendingPathComponent("empty-codex", isDirectory: true),
            traeSkillsRoots: [cn, intl])
        let trae = skills.filter { $0.source == .trae }
        try expectEqual(
            Set(trae.map(\.name)), ["byted-web-search", "arkcli-auth", "off-skill"],
            "两个渠道 + 停用区都要收")
        try expectEqual(trae.filter { !$0.enabled }.map(\.name), ["off-skill"])
    }

    t.test("记忆 vs 指令硬分割：user_profile/project_memory/topics 归记忆，user_rules 归指令") {
        let base = try makeTraeTemp()
        defer { try? FileManager.default.removeItem(at: base) }
        let cwd = "/Users/me/work/lerobot"
        let fixture = try TraeMemoryFixture(base: base, cwd: cwd)
        try fixture.addDay(
            "20260807", sessionId: "sess1", summary: "架构分析",
            summaryTime: "2026-08-07 17:51:40", turnMillis: [1_786_097_697_737])
        try Data("## Preferences\n- Communication language: Chinese\n".utf8)
            .write(to: fixture.memoryRoot.appendingPathComponent("user_profile.md"))
        // 用户手写规则：单文件 + 目录两种形态并存
        try Data("- 回复用中文\n".utf8)
            .write(to: fixture.dataFolder.appendingPathComponent("user_rules.md"))
        let rulesDir = fixture.dataFolder.appendingPathComponent("user_rules", isDirectory: true)
        try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        try Data("- commit message 用英文\n".utf8)
            .write(to: rulesDir.appendingPathComponent("commits.md"))

        let repoRoot = URL(fileURLWithPath: cwd, isDirectory: true)
        let memories = SkillMemoryIndexer.indexMemory(
            claudeHome: base.appendingPathComponent("empty-claude", isDirectory: true),
            codexHome: base.appendingPathComponent("empty-codex", isDirectory: true),
            opencodeHome: base.appendingPathComponent("empty-oc", isDirectory: true),
            claudeProjectsRoot: base.appendingPathComponent("empty-cp", isDirectory: true),
            traeMemoryRoot: fixture.memoryRoot,
            traeRulesHomes: [fixture.dataFolder],
            projectRoots: [(root: repoRoot, name: "lerobot")])
        let trae = memories.filter { $0.source == .trae }

        let asMemory = trae.filter { $0.kind != .instructions }
            .map { URL(fileURLWithPath: $0.path).lastPathComponent }
        let asInstructions = trae.filter { $0.kind == .instructions }
            .map { URL(fileURLWithPath: $0.path).lastPathComponent }
        try expectEqual(
            Set(asMemory), ["user_profile.md", "project_memory.md", "topics.md"],
            "Trae 自己写的三类归记忆")
        try expectEqual(
            Set(asInstructions), ["user_rules.md", "commits.md"],
            "用户手写规则归指令，两边计数永不共用")
        try expect(
            !asMemory.contains { $0.hasPrefix("session_memory_") },
            "逐回合流水 jsonl 不该出现在记忆页")

        // project_memory 应挂在解出的项目名下（正向编码匹配，不是那串 hash）
        let projectMemory = try expectSome(
            trae.first { $0.path.hasSuffix("project_memory.md") })
        try expectEqual(projectMemory.projectName, "lerobot")
        // topics.md 记着它覆盖了哪些会话，但一律不可跳转（Trae 没有转录文件）
        let topics = try expectSome(trae.first { $0.path.hasSuffix("topics.md") })
        try expectEqual(topics.relatedSessions.map(\.sessionId), ["sess1"])
        try expectEqual(topics.relatedSessions.first?.exists, false)
    }

    t.test("项目规则 <repo>/.trae/rules/*.md 归指令；项目技能 <repo>/.trae/skills 进项目根表") {
        let base = try makeTraeTemp()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        let rules = repo.appendingPathComponent(".trae/rules", isDirectory: true)
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        try Data("- 项目约定\n".utf8).write(to: rules.appendingPathComponent("project_rules.md"))

        let memories = SkillMemoryIndexer.indexMemory(
            claudeHome: base.appendingPathComponent("e1", isDirectory: true),
            codexHome: base.appendingPathComponent("e2", isDirectory: true),
            opencodeHome: base.appendingPathComponent("e3", isDirectory: true),
            claudeProjectsRoot: base.appendingPathComponent("e4", isDirectory: true),
            projectRoots: [(root: repo, name: "repo")])
        let trae = memories.filter { $0.source == .trae }
        try expectEqual(trae.count, 1)
        try expectEqual(trae.first?.kind, .instructions)
        try expectEqual(trae.first?.projectName, "repo")

        let projectRoots = SkillMemoryIndexer.projectSkillRoots(
            repoRoots: [(root: repo, name: "repo")])
        try expect(
            projectRoots.contains {
                $0.source == .trae && $0.root.path.hasSuffix("/repo/.trae/skills")
            },
            "项目级技能根表里必须有 trae")
    }
}

// MARK: - 计划：<repo>/.trae/documents/plan_*.md（真文件，不物化）

private func traePlanTests(_ t: TestRunner) {
    t.suite("Trae 计划")

    t.test("只收 plan_*.md；同目录其它文档不算计划") {
        let base = try makeTraeTemp()
        defer { try? FileManager.default.removeItem(at: base) }
        let docs = base.appendingPathComponent("repo/.trae/documents", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("# 重构计划\n\n- [x] 第一步\n- [ ] 第二步\n".utf8)
            .write(to: docs.appendingPathComponent("plan_20260222_091210.md"))
        try Data("# 随手记的设计稿\n".utf8)
            .write(to: docs.appendingPathComponent("design-notes.md"))

        let plans = PlanMaterializer.index(
            claudePlansDir: base.appendingPathComponent("no-claude", isDirectory: true),
            stagingRoot: base.appendingPathComponent("no-staging", isDirectory: true),
            traePlansDirs: [docs])
        try expectEqual(plans.count, 1, "design-notes.md 不该被当成计划")
        try expectEqual(plans.first?.source, .trae)
        try expectEqual(plans.first?.title, "重构计划")
        try expectEqual(plans.first?.stepsDone, 1)
        try expectEqual(plans.first?.stepsTotal, 2)
    }
}

// MARK: - 备份白名单（安全红线）

private func traeSyncWhitelistTests(_ t: TestRunner) {
    t.suite("Trae 备份白名单")

    t.test("只收技能/规则/记忆的 md；凭据与加密会话库一个都不许进") {
        let base = try makeTraeTemp()
        defer { try? FileManager.default.removeItem(at: base) }
        let dataFolder = base.appendingPathComponent("trae-cn", isDirectory: true)
        let appSupport = base.appendingPathComponent("Trae CN", isDirectory: true)
        let fm = FileManager.default

        // 该进的
        try plantSkill(
            root: dataFolder.appendingPathComponent("skills", isDirectory: true),
            name: "byted-web-search", description: "豆包搜索")
        let rulesDir = dataFolder.appendingPathComponent("user_rules", isDirectory: true)
        try fm.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        try Data("- 中文\n".utf8).write(to: rulesDir.appendingPathComponent("lang.md"))
        try Data("- 旧形态\n".utf8)
            .write(to: dataFolder.appendingPathComponent("user_rules.md"))
        let memory = dataFolder.appendingPathComponent("memory", isDirectory: true)
        try fm.createDirectory(at: memory, withIntermediateDirectories: true)
        try Data("## Preferences\n".utf8)
            .write(to: memory.appendingPathComponent("user_profile.md"))

        // 绝不该进的
        try Data("eyJhbGciOi.FAKE.TOKEN".utf8)
            .write(to: dataFolder.appendingPathComponent("trae-jwt-token"))
        try Data(#"{"mcpServers":{}}"#.utf8)
            .write(to: dataFolder.appendingPathComponent("mcp.json"))
        try Data("per-turn stream".utf8)
            .write(to: memory.appendingPathComponent("session_memory_s1.jsonl"))
        let agent = appSupport.appendingPathComponent(
            "ModularData/ai-agent", isDirectory: true)
        try fm.createDirectory(at: agent, withIntermediateDirectories: true)
        try Data("SQLCipher-encrypted".utf8).write(to: agent.appendingPathComponent("database.db"))
        try Data("cookies".utf8).write(to: appSupport.appendingPathComponent("Cookies"))

        var roots = try emptySyncRoots(base: base)
        roots.traeRoots = [
            (dataFolder.appendingPathComponent("skills", isDirectory: true), "trae/skills"),
            (rulesDir, "trae/rules"),
            (dataFolder.appendingPathComponent("user_rules.md"), "trae/rules"),
            (memory, "trae/memory"),
        ]
        let result = SyncSourceCatalog.enumerate(
            roots: roots, prefix: "eureka", host: "host", maxFileSize: 10 * 1024 * 1024)
        let names = result.candidates.map { URL(fileURLWithPath: $0.localPath).lastPathComponent }

        try expectEqual(
            Set(names), ["SKILL.md", "lang.md", "user_rules.md", "user_profile.md"])
        for forbidden in [
            "trae-jwt-token", "mcp.json", "database.db", "Cookies", "session_memory_s1.jsonl",
        ] {
            try expect(!names.contains(forbidden), "\(forbidden) 绝不能进备份")
        }
        try expect(
            result.candidates.allSatisfy { !$0.localPath.contains("ModularData") },
            "Application Support 下的任何东西都不该被枚举到")
    }
}

// MARK: - fixture

private func makeTraeTemp() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("eureka-trae-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

private func plantSkill(root: URL, name: String, description: String) throws {
    let dir = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let body = "---\nname: \(name)\ndescription: \(description)\n---\n\n正文\n"
    try Data(body.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
}

/// Trae CN 记忆库的真实布局：
/// ```
/// <dataFolder>/memory/user_profile.md
/// <dataFolder>/memory/projects/<encoded>--p2-<hash>/project_memory.md
/// <dataFolder>/memory/projects/<encoded>--p2-<hash>/<YYYYMMDD>/topics.md
/// <dataFolder>/memory/projects/<encoded>--p2-<hash>/<YYYYMMDD>/session_memory_<id>.jsonl
/// <appSupport>/User/workspaceStorage/<hash>/workspace.json   ← cwd 的唯一非有损来源
/// ```
private struct TraeMemoryFixture {
    let dataFolder: URL
    let appSupport: URL
    let memoryRoot: URL
    let projectsRoot: URL
    let projectDir: URL
    let workspaceStorageRoot: URL

    init(base: URL, cwd: String) throws {
        let fm = FileManager.default
        dataFolder = base.appendingPathComponent("trae-cn", isDirectory: true)
        appSupport = base.appendingPathComponent("Trae CN", isDirectory: true)
        memoryRoot = dataFolder.appendingPathComponent("memory", isDirectory: true)
        projectsRoot = memoryRoot.appendingPathComponent("projects", isDirectory: true)
        // 目录名 = 正向编码的 cwd + `--p<N>-<hash>` 后缀（实勘形态）
        let encoded = SkillMemoryIndexer.encodeProjectDirName(cwd)
        projectDir = projectsRoot.appendingPathComponent(
            "\(encoded)--p2-832ae42141a2828b9304", isDirectory: true)
        workspaceStorageRoot = appSupport.appendingPathComponent(
            "User/workspaceStorage", isDirectory: true)

        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data("## Hard Constraints\n- 必须走统一接口\n".utf8)
            .write(to: projectDir.appendingPathComponent("project_memory.md"))

        let workspace = workspaceStorageRoot
            .appendingPathComponent("85b58a3a8bfb2b74", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        let json = #"{"folder":"file://\#(cwd)"}"#
        try Data(json.utf8).write(to: workspace.appendingPathComponent("workspace.json"))
    }

    func addDay(
        _ day: String, sessionId: String, summary: String, summaryTime: String,
        turnMillis: [Int]
    ) throws {
        let dir = projectDir.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let topics = "[session_id: \(sessionId) | topic_summary_time: \(summaryTime)]\(summary)"
        try Data(topics.utf8).write(to: dir.appendingPathComponent("topics.md"))

        let lines = turnMillis.map { millis in
            #"{"intent":"i","actions":["a"],"outcome":"o","learned":[],"message_summary_time":"\#(summaryTime)","message_id":"m","compact_summary_meta":{"trigger":"auto","mode":"async","created_at_ms":\#(millis)}}"#
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: dir.appendingPathComponent("session_memory_\(sessionId).jsonl"))
    }
}

/// 全部源都指向临时空目录的 SyncRoots —— 只留 traeRoots 由调用方填。
/// 漏传任何一个根都会让 enumerate 去读真实 ~/，测试就不自洽了。
private func emptySyncRoots(base: URL) throws -> SyncRoots {
    func dir(_ name: String) -> URL {
        base.appendingPathComponent("empty-\(name)", isDirectory: true)
    }
    return SyncRoots(
        claudeHome: dir("claude-home"), claudeProjects: dir("claude-proj"),
        claudeSkills: dir("claude-skills"),
        codexHome: dir("codex-home"), codexSessions: dir("codex-sess"),
        codexSkills: dir("codex-skills"),
        opencodeSkills: dir("oc-skills"), opencodeDB: dir("oc").appendingPathComponent("oc.db"),
        grokSkills: dir("grok-skills"), grokMemory: dir("grok-mem"),
        grokSessions: dir("grok-sess"),
        kimiSkills: dir("kimi-skills"), kimiSessions: dir("kimi-sess"),
        geminiHome: dir("gemini-home"), geminiSessions: dir("gemini-sess"),
        geminiSkills: dir("gemini-skills"),
        qwenProjects: dir("qwen-proj"), qwenMemories: dir("qwen-mem"),
        qwenSkills: dir("qwen-skills"),
        hermesSkills: dir("hermes-skills"), hermesMemories: dir("hermes-mem"),
        hermesHome: dir("hermes-home"), hermesPlans: dir("hermes-plans"),
        claudePlans: dir("claude-plans"), plansStaging: dir("plans-staging"))
}
