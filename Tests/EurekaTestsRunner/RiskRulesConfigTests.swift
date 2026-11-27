import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

func riskRulesConfigTests(_ t: TestRunner) {
    t.suite("审计规则配置 · audit-rules.json")

    let home = "/Users/me"
    let builtin = RiskRuleEngine.builtinRules
    func parse(_ json: String) throws -> (config: RiskRulesConfig, problems: [RiskRuleSet.Problem]) {
        try RiskRulesConfig.parse(Data(json.utf8))
    }
    func rules(_ json: String) throws -> RiskRuleSet {
        let parsed = try parse(json)
        return RiskRuleSet.make(builtin: builtin, config: parsed.config, problems: parsed.problems)
    }
    func hit(
        _ set: RiskRuleSet, _ detail: String, kind: ToolKind = .command, cwd: String? = nil,
        source: AgentSource? = nil, tool: String = ""
    ) -> String? {
        set.evaluate(kind: kind, tool: tool, detail: detail, cwd: cwd, source: source, home: home)?.ruleId
    }

    t.test("overrides：关闭内置规则、改等级；内置的默认关闭规则可以打开") {
        let set = try rules(#"""
        {"overrides": {"sudo": {"enabled": false}, "git-push-main": {"level": "high"},
                       "remote-package-run": {"enabled": true}}}
        """#)
        try expectEqual(set.problems, [])
        try expect(hit(set, "sudo ls") == nil)
        try expectEqual(
            set.evaluate(kind: .command, tool: "", detail: "git push origin main", home: home)?.level, .high)
        try expectEqual(hit(set, "npx create-vite app"), "remote-package-run")
        // Untouched rules stay as they were
        try expectEqual(hit(set, "cat .env"), "read-env-file")
    }

    t.test("自定义规则：和内置规则同样的字段，同级里排在内置规则前面") {
        let set = try rules(#"""
        {"rules": [
          {"id": "prod-db", "title": "连接生产库", "level": "critical", "kinds": ["command"],
           "scope": "segment", "commands": ["psql", "mysql"], "pattern": "prod", "exclude": ["--dry-run"]},
          {"id": "deploy-script", "title": "Deploy", "level": "high", "pattern": "\\bdeploy\\.sh\\b"},
          {"id": "internal-mcp", "level": "notice", "scope": "tool", "pattern": "\\.query_bigquery$"},
          {"id": "secrets-dir", "level": "critical", "scope": "path", "access": "read",
           "pattern": "/secrets/"}
        ]}
        """#)
        try expectEqual(set.problems, [])
        let found = set.evaluate(kind: .command, tool: "", detail: "psql -h prod-db.internal", home: home)
        try expectEqual(found?.ruleId, "prod-db")
        try expectEqual(found?.title, "连接生产库")
        try expectEqual(found?.level, .critical)
        try expect(hit(set, "psql -h prod-db.internal --dry-run") == nil)
        try expect(hit(set, "psql -h staging") == nil)
        try expect(hit(set, "echo prod | grep psql") == nil, "命令词要是 psql")
        // No commands given: the scope defaults to the whole text, the kind to commands
        try expectEqual(hit(set, "bash scripts/deploy.sh staging"), "deploy-script")
        try expectEqual(hit(set, "", kind: .mcp, tool: "Data-Bigquery.query_bigquery"), "internal-mcp")
        try expectEqual(hit(set, "/repo/secrets/prod.yaml", kind: .read), "secrets-dir")
        try expectEqual(hit(set, "cat /repo/secrets/prod.yaml"), "secrets-dir")
        try expect(hit(set, "/repo/secrets/prod.yaml", kind: .edit) == nil, "只看读取")
    }

    t.test("白名单：按规则、项目目录、来源、正则任意组合；让出后更低的规则仍可命中") {
        let set = try rules(#"""
        {"allow": [
          {"rule": "rm-rf", "cwd": "/Users/me/scratch"},
          {"rule": "*", "pattern": "^make clean\\b"},
          {"rule": "sudo", "source": "codex"}
        ]}
        """#)
        try expectEqual(set.problems, [])
        try expect(hit(set, "rm -rf /Users/me/other", cwd: "/Users/me/scratch") == nil)
        try expect(hit(set, "rm -rf /Users/me/other", cwd: "/Users/me/scratch/sub") == nil)
        try expectEqual(hit(set, "rm -rf /Users/me/other", cwd: "/Users/me/scratch2"), "rm-rf")
        try expectEqual(hit(set, "rm -rf /Users/me/other", cwd: nil), "rm-rf")
        try expect(hit(set, "make clean && sudo rm -rf /srv/x") == nil)
        try expectEqual(hit(set, "sudo ls", source: .claude), "sudo")
        try expect(hit(set, "sudo ls", source: .codex) == nil)
        // The allowed high rule steps aside; the notice below it still speaks
        try expectEqual(hit(set, "sudo rm -rf /Users/me/other", cwd: "/Users/me/scratch"), "sudo")
    }

    t.test("坏配置不让规则失效：坏条目跳过并报告，其余照常") {
        let parsed = try parse(#"""
        {"overrides": {"no-such-rule": {"enabled": false}, "sudo": {"level": "urgent"}},
         "rules": [
           {"id": "bad-regex", "level": "high", "pattern": "("},
           {"id": "rm-rf", "level": "high", "pattern": "x"},
           {"id": "no-level", "pattern": "x"},
           {"id": "matches-everything", "level": "high"},
           {"id": "bad-kind", "level": "high", "pattern": "x", "kinds": ["shell"]},
           {"id": "good", "level": "notice", "pattern": "\\bterraform\\b"},
           {"id": "good", "level": "notice", "pattern": "y"},
           "not an object"
         ],
         "allow": [{"cwd": "/x"}, {"rule": "*"}, {"rule": "sudo", "pattern": "["}]}
        """#)
        let set = RiskRuleSet.make(builtin: builtin, config: parsed.config, problems: parsed.problems)
        let reported = Set(set.problems.map(\.ruleId))
        try expectEqual(reported, [
            "no-such-rule", "sudo", "bad-regex", "rm-rf", "no-level", "matches-everything",
            "bad-kind", "good", "rules[7]", "allow[0]", "allow[1]", "allow:sudo",
        ])
        // The good rule and every built-in rule still work
        try expectEqual(hit(set, "terraform plan"), "good")
        try expectEqual(hit(set, "sudo rm -rf /"), "rm-rf")
        try expectEqual(hit(set, "sudo ls"), "sudo")
        // Not a JSON object at all: the caller keeps what it had
        do {
            _ = try parse("[1, 2]")
            try expect(false, "应抛出 notAnObject")
        } catch let error as RiskRulesConfig.ParseError {
            try expectEqual(error, .notAnObject)
        }
        do {
            _ = try parse("{ not json")
            try expect(false, "应抛出 notAnObject")
        } catch let error as RiskRulesConfig.ParseError {
            try expectEqual(error, .notAnObject)
        }
    }

    t.test("写出再读回不变；指纹随 overrides / 自定义规则 / 白名单变化") {
        let original = try parse(#"""
        {"overrides": {"sudo": {"enabled": false}, "git-push-main": {"level": "high"}},
         "rules": [{"id": "prod-db", "title": "Prod", "level": "critical", "commands": ["psql"],
                    "pattern": "prod", "exclude": ["--dry-run"], "topLevel": true,
                    "notPipedInto": ["grep"], "targets": ["home"], "access": "read"}],
         "allow": [{"rule": "rm-rf", "cwd": "/Users/me/scratch", "source": "codex", "pattern": "x"}]}
        """#).config
        let again = try RiskRulesConfig.parse(try original.encoded())
        try expectEqual(again.problems, [])
        try expectEqual(again.config, original)

        let base = RiskRuleSet.make(builtin: builtin, config: RiskRulesConfig()).fingerprint
        var changed = RiskRulesConfig(overrides: ["sudo": .init(enabled: false)])
        try expect(RiskRuleSet.make(builtin: builtin, config: changed).fingerprint != base)
        changed = RiskRulesConfig(allow: [.init(rule: "sudo", cwd: "/x")])
        try expect(RiskRuleSet.make(builtin: builtin, config: changed).fingerprint != base)
        try expectEqual(RiskRuleSet.make(builtin: builtin, config: RiskRulesConfig()).fingerprint, base)
    }

    t.test("规则文件：没有文件用内置规则；保存后生效；手改能发现；整个文件坏掉保留上一份") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The engine's rule set is process-wide: put the built-in one back when done
        defer {
            try? FileManager.default.removeItem(at: dir)
            RiskRuleEngine.install(RiskRuleSet(rules: RiskRuleEngine.builtinRules))
        }
        let store = RiskRuleStore(url: dir.appendingPathComponent("audit-rules.json"))
        try expectEqual(store.load(), RiskRuleStore.State())
        try expectEqual(RiskRuleEngine.evaluate(kind: .command, tool: "", detail: "sudo ls")?.ruleId, "sudo")

        let saved = try store.save(RiskRulesConfig(overrides: ["sudo": .init(enabled: false)]))
        try expectEqual(saved.problems, [])
        try expect(RiskRuleEngine.evaluate(kind: .command, tool: "", detail: "sudo ls") == nil)
        try expect(store.reloadIfChanged() == nil, "自己刚写的不算变化")

        // A hand edit, with a broken entry next to a good one
        try Data(#"{"overrides": {"sudo": {"enabled": true}}, "rules": [{"id": "x", "level": "high", "pattern": "("}]}"#.utf8)
            .write(to: store.url)
        let edited = store.reloadIfChanged()
        try expectEqual(edited?.problems.map(\.ruleId), ["x"])
        try expect(edited?.fileError == nil)
        try expectEqual(RiskRuleEngine.evaluate(kind: .command, tool: "", detail: "sudo ls")?.ruleId, "sudo")

        // The whole file unusable: the rules from before stay in force
        try Data("oops".utf8).write(to: store.url)
        let broken = store.reloadIfChanged()
        try expect(broken?.fileError != nil)
        try expectEqual(broken?.config, edited?.config)
        try expectEqual(RiskRuleEngine.evaluate(kind: .command, tool: "", detail: "sudo ls")?.ruleId, "sudo")
        try expectEqual(RiskRuleEngine.evaluate(kind: .command, tool: "", detail: "cat .env")?.level, .critical)
    }

    t.test("保存前试算：一条规则在历史里会命中多少") {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-rules-preview-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        for (index, detail) in ["terraform plan", "terraform apply", "ls", "echo terraform"].enumerated() {
            try store.audit.insert(AuditEvent(
                opId: "op\(index)", source: .codex, sessionId: "s",
                timestamp: Date(timeIntervalSince1970: Double(index)), kind: .command,
                tool: "exec_command", detail: detail))
        }
        let rule = RiskRule(
            id: "tf", title: RiskRuleTitle("tf"), level: .notice, category: .custom,
            kinds: [.command], scope: .segment, commands: ["terraform"])
        try expectEqual(try RiskRuleStore.historicalHits(of: rule, store: store, home: home), 2)
        try expectEqual(try store.audit.count(.init(riskOnly: true)), 0, "试算不写库")
    }
}
