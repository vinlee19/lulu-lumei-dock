import EurekaInstall
import Foundation

func hookDiagnosticsTests(_ t: TestRunner) {
    t.suite("hook 诊断 · 异常识别与他人配置共存")

    let stable = "/Users/demo/Library/Application Support/Eureka/bin/eureka-relay"
    /// Relay is assumed executable by default; pass { _ in false } to test relayMissing
    let present: (String) -> Bool = { _ in true }

    /// Builds an installed settings.json (others' hooks can be injected)
    func installedJSON(relayPath: String = stable, withForeign: Bool = false) throws -> String {
        var json = try ClaudeHooksInstaller.install(into: "{}", relayPath: relayPath)
        guard withForeign else { return json }
        var root = try ClaudeHooksInstaller.parseForTest(json)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // Mirror the real local setup: otty-cli's hooks sit alongside ours on the same event
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
        // We can fix this one ourselves (rebuild the forwarder), so it must not block automatic
        // writes
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
        // Our own entries must not be counted as "others"
        try expect(!report.tools.contains { $0.contains("eureka") })
    }

    t.test("装卸他人 hook 逐字不动（共存回归，仿本机真实形态）") {
        let json = try installedJSON(withForeign: true)
        // After uninstall: all our entries are gone, and both otty-cli entries must remain
        // untouched
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
        // Reinstall: others' entries are still there (idempotent + no collateral damage)
        let reinstalled = try ClaudeHooksInstaller.install(
            into: uninstalled, relayPath: stable)
        try expect(reinstalled.contains("otty-cli"))
        try expectEqual(
            ClaudeHooksInstaller.diagnose(
                json: reinstalled, expectedRelayPath: stable, relayIsExecutable: present),
            .installed)
    }

    t.test("认不出的 hooks 形态：拒绝改写而不是把它当空数组覆盖掉") {
        // Real risk: when an event value isn't an entry array, entriesOf returns [], and install
        // then sets hooks[event] = [our entry], wiping the original content. This must be refused.
        let shapes = [
            // Array mixed with null / strings
            "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"command\":\"x\"}]},null]}}",
            // Event value is an object, not an array
            "{\"hooks\":{\"Stop\":{\"hooks\":[{\"command\":\"x\"}]}}}",
            // Event value is a string
            "{\"hooks\":{\"Stop\":\"some-command\"}}",
        ]
        for json in shapes {
            let diagnosis = ClaudeHooksInstaller.diagnose(
                json: json, expectedRelayPath: stable, relayIsExecutable: present)
            guard case .unparseable = diagnosis else {
                throw ExpectationError(description: "应判为 unparseable，实际 \(diagnosis)")
            }
            try expect(diagnosis.blocksAutomaticWrite, "看不懂的形态必须禁止自动写")

            var installThrew = false
            do { _ = try ClaudeHooksInstaller.install(into: json, relayPath: stable) }
            catch { installThrew = true }
            try expect(installThrew, "install 必须抛错而不是覆盖：\(json)")

            var uninstallThrew = false
            do { _ = try ClaudeHooksInstaller.uninstall(from: json) }
            catch { uninstallThrew = true }
            try expect(uninstallThrew, "uninstall 同样不该删掉看不懂的内容：\(json)")
        }
    }

    t.test("正常形态不受形态校验影响（不能把好配置也拒了）") {
        let json = try installedJSON(withForeign: true)
        try expectEqual(
            ClaudeHooksInstaller.diagnose(
                json: json, expectedRelayPath: stable, relayIsExecutable: present),
            .installed)
        _ = try ClaudeHooksInstaller.install(into: json, relayPath: stable)
        _ = try ClaudeHooksInstaller.uninstall(from: json)
        // Empty hooks / no hooks key must work as usual
        _ = try ClaudeHooksInstaller.install(into: "{}", relayPath: stable)
        _ = try ClaudeHooksInstaller.install(into: "{\"hooks\":{}}", relayPath: stable)
    }

    // MARK: - Codex notify

    t.test("Codex：他人占用顶层 notify 且能解析 → chainable，允许手动串联、不算已安装") {
        let toml = "notify = [\"/opt/homebrew/bin/other-tool\", \"notify\"]\n\n[tui]\n"
        let diagnosis = CodexNotifyInstaller.diagnose(
            toml: toml, expectedRelayPath: stable, relayIsExecutable: present)
        try expectEqual(diagnosis, .chainable(owner: "other-tool"))
        try expect(!diagnosis.blocksAutomaticWrite, "串联不覆盖原程序，可以由用户手动打开")
        try expect(!diagnosis.isInstalledInSomeForm, "自动更新绝不能顺手把它装上")
    }

    t.test("Codex：他人 notify 解析不了（跨多行）→ foreignOccupied 且拒绝写") {
        let toml = "notify = [\n  \"/opt/bin/other-tool\",\n  \"notify\",\n]\n\n[tui]\n"
        let diagnosis = CodexNotifyInstaller.diagnose(
            toml: toml, expectedRelayPath: stable, relayIsExecutable: present)
        guard case .foreignOccupied = diagnosis else {
            throw ExpectationError(description: "应为 foreignOccupied，实际 \(diagnosis)")
        }
        try expect(diagnosis.blocksAutomaticWrite, "看不懂的 notify 不许改")
        do {
            _ = try CodexNotifyInstaller.install(into: toml, relayPath: stable)
            throw ExpectationError(description: "应抛 foreignConfig")
        } catch InstallError.foreignConfig {}
    }

    t.test("Codex：他人写的 notify = [] 等于没配置") {
        try expectEqual(
            CodexNotifyInstaller.diagnose(
                toml: "notify = []\n", expectedRelayPath: stable, relayIsExecutable: present),
            .notInstalled)
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
            .foreignOccupied(detail: "被占"), .legacyRelayName(found: ["x"]),
            .chainable(owner: "other-tool"),
        ]
        for diagnosis in cases {
            try expect(!diagnosis.label.isEmpty, "\(diagnosis) 缺标签")
            try expect(diagnosis.detail?.isEmpty == false, "\(diagnosis) 缺给用户的解释")
        }
        // A healthy state must carry no noisy explanation
        try expect(HookDiagnosis.installed.detail == nil)
        try expect(HookDiagnosis.notInstalled.detail == nil)
    }

    // MARK: - relay rename (eureka-relay → lululumei-relay)

    let renamedStable = "/Users/demo/Library/Application Support/Eureka/bin/lululumei-relay"
    let legacyStable = "/Users/demo/Library/Application Support/Eureka/bin/eureka-relay"

    t.test("旧名稳定路径 → legacyRelayName：可自动迁移，不算漂移") {
        let claude = ClaudeHooksInstaller.diagnose(
            json: try installedJSON(relayPath: legacyStable),
            expectedRelayPath: renamedStable, relayIsExecutable: present)
        guard case .legacyRelayName(let found) = claude else {
            throw ExpectationError(description: "应为 legacyRelayName，实际 \(claude)")
        }
        try expectEqual(found.count, ClaudeHooksInstaller.managedEvents.count)
        try expect(!claude.blocksAutomaticWrite, "我们自己的旧路径，自动更新可以迁移")
        try expect(claude.isInstalledInSomeForm, "旧名条目仍然在工作，算已安装")

        let codexHooks = try CodexHooksInstaller.install(into: "{}", relayPath: legacyStable)
        guard case .legacyRelayName = CodexHooksInstaller.diagnose(
            json: codexHooks, expectedRelayPath: renamedStable, relayIsExecutable: present) else {
            throw ExpectationError(description: "Codex hooks 旧名应判为 legacyRelayName")
        }
        let trae = try TraeHooksInstaller.install(into: "{}", relayPath: legacyStable)
        guard case .legacyRelayName = TraeHooksInstaller.diagnose(
            json: trae, expectedRelayPath: renamedStable, relayIsExecutable: present) else {
            throw ExpectationError(description: "Trae hooks 旧名应判为 legacyRelayName")
        }
        let notify = try CodexNotifyInstaller.install(into: "[tui]\n", relayPath: legacyStable)
        guard case .legacyRelayName = CodexNotifyInstaller.diagnose(
            toml: notify, expectedRelayPath: renamedStable, relayIsExecutable: present) else {
            throw ExpectationError(description: "Codex notify 旧名应判为 legacyRelayName")
        }
    }

    t.test("旧名但不在稳定目录（旧 app-bundle）→ 仍是 driftedPath") {
        let diagnosis = ClaudeHooksInstaller.diagnose(
            json: try installedJSON(relayPath: "/Applications/old.app/Contents/MacOS/eureka-relay"),
            expectedRelayPath: renamedStable, relayIsExecutable: present)
        guard case .driftedPath = diagnosis else {
            throw ExpectationError(description: "应为 driftedPath，实际 \(diagnosis)")
        }
    }

    t.test("重装把旧名条目替换为新名，不留重复；卸载新旧都清干净") {
        let old = try installedJSON(relayPath: legacyStable, withForeign: true)
        let migrated = try ClaudeHooksInstaller.install(into: old, relayPath: renamedStable)
        try expect(!migrated.contains(RelayIdentity.legacyBinaryName), "旧名条目应被替换")
        try expectEqual(
            ClaudeHooksInstaller.diagnose(
                json: migrated, expectedRelayPath: renamedStable, relayIsExecutable: present),
            .installed)
        try expect(migrated.contains("otty-cli"), "他人条目原样保留")

        let uninstalled = try ClaudeHooksInstaller.uninstall(from: old)
        try expect(!uninstalled.contains(RelayIdentity.legacyBinaryName), "旧名条目卸载要认得")
        try expect(uninstalled.contains("otty-cli"))
    }

    t.test("RelayIdentity：只认我们的两个名字") {
        try expect(RelayIdentity.isOurs("\"/x/lululumei-relay\" claude-hook"))
        try expect(RelayIdentity.isOurs("\"/x/eureka-relay\" claude-hook"))
        try expect(!RelayIdentity.isOurs("'/opt/homebrew/bin/otty-cli' hook"))
        try expect(RelayIdentity.isLegacyStablePath(legacyStable, expected: renamedStable))
        try expect(!RelayIdentity.isLegacyStablePath(legacyStable, expected: legacyStable),
                   "期望路径本身就是旧名时不算迁移")
        try expect(!RelayIdentity.isLegacyStablePath("/elsewhere/eureka-relay", expected: renamedStable))
    }
}

/// Helper: fail when an Optional can't be unwrapped
private func require<T>(
    _ value: T?, file: StaticString = #filePath, line: UInt = #line
) throws -> T {
    guard let value else {
        throw ExpectationError(description: "期望非 nil，实际为 nil at \(file):\(line)")
    }
    return value
}
