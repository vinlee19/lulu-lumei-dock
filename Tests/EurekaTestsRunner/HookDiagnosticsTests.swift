import EurekaInstall
import Foundation

func hookDiagnosticsTests(_ t: TestRunner) {
    t.suite("hook 诊断 · 异常识别与他人配置共存")

    let stable = "/Users/demo/Library/Application Support/Eureka/bin/eureka-relay"
    /// 默认认为 relay 可执行；要测 relayMissing 时传 { _ in false }
    let present: (String) -> Bool = { _ in true }

    /// 造一份装好的 settings.json（可注入他人 hook）
    func installedJSON(relayPath: String = stable, withForeign: Bool = false) throws -> String {
        var json = try ClaudeHooksInstaller.install(into: "{}", relayPath: relayPath)
        guard withForeign else { return json }
        var root = try ClaudeHooksInstaller.parseForTest(json)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // 模拟本机真实形态：otty-cli 的 hook 与我们并存在同一事件上
        for event in ["PreToolUse", "Stop"] {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.append([
                "hooks": [["type": "command", "command": "'/opt/homebrew/bin/otty-cli' hook"]],
            ])
            hooks[event] = entries
        }
        root["hooks"] = hooks
        json = try ClaudeHooksInstaller.serializeForTest(root)
        return json
    }

    t.test("干净未安装 / 装好 两个基本态") {
        try expectEqual(
            ClaudeHooksInstaller.diagnose(
                json: "{}", expectedRelayPath: stable, relayIsExecutable: present),
            .notInstalled)
        try expectEqual(
            ClaudeHooksInstaller.diagnose(
                json: try installedJSON(), expectedRelayPath: stable,
                relayIsExecutable: present),
            .installed)
    }

    t.test("配置不是合法 JSON → unparseable 且禁止自动写入（不能显示成「未安装」）") {
        let diagnosis = ClaudeHooksInstaller.diagnose(
            json: "{ 这不是 json ", expectedRelayPath: stable, relayIsExecutable: present)
        guard case .unparseable = diagnosis else {
            throw ExpectationError(description: "应为 unparseable，实际 \(diagnosis)")
        }
        try expect(diagnosis.blocksAutomaticWrite, "看不懂的配置绝不能自动改")
        try expect(!diagnosis.isInstalledInSomeForm, "解析不了不能算已安装")
    }

    t.test("路径被手改 / 残留旧 app-bundle 路径 → driftedPath，且不自动修") {
        let diagnosis = ClaudeHooksInstaller.diagnose(
            json: try installedJSON(relayPath: "/Applications/old.app/Contents/MacOS/eureka-relay"),
            expectedRelayPath: stable, relayIsExecutable: present)
        guard case .driftedPath(let found) = diagnosis else {
            throw ExpectationError(description: "应为 driftedPath，实际 \(diagnosis)")
        }
        try expect(!found.isEmpty)
        try expect(diagnosis.blocksAutomaticWrite, "可能是用户手改的，无权覆盖")
        try expect(diagnosis.isInstalledInSomeForm, "确实装着，只是指向不对")
    }

    t.test("relay 不可执行 → relayMissing（事件静默全挂，最隐蔽的故障）") {
        let diagnosis = ClaudeHooksInstaller.diagnose(
            json: try installedJSON(), expectedRelayPath: stable,
            relayIsExecutable: { _ in false })
        try expectEqual(diagnosis, .relayMissing(path: stable))
        try expectEqual(diagnosis.severity, .error)
        // 这个是我们自己能修好的（重建转发器），所以不该阻止自动写入
        try expect(!diagnosis.blocksAutomaticWrite)
    }

    t.test("受管事件集变大（app 升级）→ stale，列出缺哪些") {
        var root = try ClaudeHooksInstaller.parseForTest(try installedJSON())
        var hooks = try require(root["hooks"] as? [String: Any])
        hooks.removeValue(forKey: "SessionEnd")
        root["hooks"] = hooks
        let diagnosis = ClaudeHooksInstaller.diagnose(
            json: try ClaudeHooksInstaller.serializeForTest(root),
            expectedRelayPath: stable, relayIsExecutable: present)
        try expectEqual(diagnosis, .stale(missing: ["SessionEnd"]))
        try expect(!diagnosis.blocksAutomaticWrite, "缺事件是可以自动补齐的")
    }

    t.test("他人 hook 共存：能报出来，且不影响自身诊断为已安装") {
        let json = try installedJSON(withForeign: true)
        let diagnosis = ClaudeHooksInstaller.diagnose(
            json: json, expectedRelayPath: stable, relayIsExecutable: present)
        try expectEqual(diagnosis, .installed, "别人的 hook 不该让我们自己的判定失真")

        let report = ClaudeHooksInstaller.foreignHooks(in: json)
        try expectEqual(report.tools, ["otty-cli"], "应只报出他人的工具短名")
        try expectEqual(report.events, ["PreToolUse", "Stop"])
        // 自己的条目不该被算成"他人"
        try expect(!report.tools.contains { $0.contains("eureka") })
    }

    t.test("装卸他人 hook 逐字不动（共存回归，仿本机真实形态）") {
        let json = try installedJSON(withForeign: true)
        // 卸载后：我们的条目全没了，otty-cli 的两条必须原样都在
        let uninstalled = try ClaudeHooksInstaller.uninstall(from: json)
        try expect(!uninstalled.contains("eureka-relay"), "自有条目应清干净")
        let root = try ClaudeHooksInstaller.parseForTest(uninstalled)
        let hooks = try require(root["hooks"] as? [String: Any])
        for event in ["PreToolUse", "Stop"] {
            let entries = hooks[event] as? [[String: Any]] ?? []
            let commands = entries.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .compactMap { $0["command"] as? String }
            try expect(
                commands.contains { $0.contains("otty-cli") },
                "\(event) 上他人的 hook 被误删了")
        }
        // 再装回来：他人条目仍在（幂等 + 不误伤）
        let reinstalled = try ClaudeHooksInstaller.install(
            into: uninstalled, relayPath: stable)
        try expect(reinstalled.contains("otty-cli"))
        try expectEqual(
            ClaudeHooksInstaller.diagnose(
                json: reinstalled, expectedRelayPath: stable, relayIsExecutable: present),
            .installed)
    }

    // MARK: - Codex notify

    t.test("Codex：他人占用顶层 notify → foreignOccupied 且拒绝自动写") {
        let toml = "notify = [\"/opt/homebrew/bin/other-tool\", \"notify\"]\n\n[tui]\n"
        let diagnosis = CodexNotifyInstaller.diagnose(
            toml: toml, expectedRelayPath: stable, relayIsExecutable: present)
        guard case .foreignOccupied = diagnosis else {
            throw ExpectationError(description: "应为 foreignOccupied，实际 \(diagnosis)")
        }
        try expect(diagnosis.blocksAutomaticWrite, "notify 只能有一个，不许覆盖别人的")
        try expect(!diagnosis.isInstalledInSomeForm)
    }

    t.test("Codex：未配置 / 装好 / 路径歪了 / relay 缺失") {
        try expectEqual(
            CodexNotifyInstaller.diagnose(
                toml: "[tui]\n", expectedRelayPath: stable, relayIsExecutable: present),
            .notInstalled)

        let installed = try CodexNotifyInstaller.install(into: "[tui]\n", relayPath: stable)
        try expectEqual(
            CodexNotifyInstaller.diagnose(
                toml: installed, expectedRelayPath: stable, relayIsExecutable: present),
            .installed)
        try expectEqual(
            CodexNotifyInstaller.diagnose(
                toml: installed, expectedRelayPath: stable,
                relayIsExecutable: { _ in false }),
            .relayMissing(path: stable))

        let drifted = try CodexNotifyInstaller.install(
            into: "[tui]\n", relayPath: "/old/path/eureka-relay")
        guard case .driftedPath = CodexNotifyInstaller.diagnose(
            toml: drifted, expectedRelayPath: stable, relayIsExecutable: present) else {
            throw ExpectationError(description: "旧路径应判为 driftedPath")
        }
    }

    t.test("诊断都带得走的展示信息：标签 + 说明（异常必须有解释）") {
        let cases: [HookDiagnosis] = [
            .stale(missing: ["Stop"]), .driftedPath(found: ["x"]),
            .relayMissing(path: "/x"), .unparseable(reason: "坏了"),
            .foreignOccupied(detail: "被占"),
        ]
        for diagnosis in cases {
            try expect(!diagnosis.label.isEmpty, "\(diagnosis) 缺标签")
            try expect(diagnosis.detail?.isEmpty == false, "\(diagnosis) 缺给用户的解释")
        }
        // 正常态不该有噪音说明
        try expect(HookDiagnosis.installed.detail == nil)
        try expect(HookDiagnosis.notInstalled.detail == nil)
    }
}

/// 小工具：Optional 解包失败即报错
private func require<T>(
    _ value: T?, file: StaticString = #filePath, line: UInt = #line
) throws -> T {
    guard let value else {
        throw ExpectationError(description: "期望非 nil，实际为 nil at \(file):\(line)")
    }
    return value
}
