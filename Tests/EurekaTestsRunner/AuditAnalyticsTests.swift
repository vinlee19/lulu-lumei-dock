import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

func auditAnalyticsTests(_ t: TestRunner) {
    t.suite("审计统计 · 模型归属与分组")

    func tempStore() throws -> (EurekaStore, URL) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-audit-analytics-\(UUID()).sqlite")
        return (try EurekaStore(path: path), path)
    }

    func op(
        _ id: String, _ ts: Double, session: String = "s1", source: AgentSource = .claude,
        kind: ToolKind = .command, tool: String = "Bash", detail: String = "ls",
        cwd: String? = "/Users/me/repo", error: Bool = false
    ) -> AuditEvent {
        AuditEvent(
            opId: id, source: source, sessionId: session,
            timestamp: Date(timeIntervalSince1970: ts), kind: kind, tool: tool, detail: detail,
            cwd: cwd, isError: error)
    }

    func usage(_ model: String, _ ts: Double, session: String = "s1", source: AgentSource = .claude) -> UsageRecord {
        UsageRecord(
            source: source, model: model, sessionId: session,
            timestamp: Date(timeIntervalSince1970: ts), inputTokens: Int(ts), outputTokens: 1)
    }

    t.test("归属：取发出调用的那一次模型调用，超出时间窗不归属") {
        let timeline: [(ts: Double, model: String)] = [(100, "a"), (200, "b"), (2000, "c")]
        // The call just before the operation issued it
        try expectEqual(AuditModelAttributor.model(at: 150, in: timeline), "a")
        try expectEqual(AuditModelAttributor.model(at: 205, in: timeline), "b")
        // A hook can land a few seconds before its usage row is stamped
        try expectEqual(AuditModelAttributor.model(at: 197, in: timeline), "b")
        // A long-running tool reports late, up to ten minutes
        try expectEqual(AuditModelAttributor.model(at: 790, in: timeline), "b")
        // Too long after the last call, but one follows within a minute
        try expectEqual(AuditModelAttributor.model(at: 1950, in: timeline), "c")
        try expect(AuditModelAttributor.model(at: 1200, in: timeline) == nil)
        try expect(AuditModelAttributor.model(at: 50, in: [(200, "b")]) == nil)
        try expect(AuditModelAttributor.model(at: 50, in: []) == nil)
    }

    t.test("归属批处理：对上的写模型，过期对不上的写空串，近期对不上的留着重试；归档指纹不动") {
        let (store, path) = try tempStore()
        defer { try? FileManager.default.removeItem(at: path) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recent = now.timeIntervalSince1970 - 3_600
        _ = try store.usage.insert([
            usage("opus", recent), usage("haiku", recent + 300),
            usage("gpt", recent, session: "c1", source: .codex),
        ])
        try store.audit.insert(op("a", recent + 10))                       // opus
        try store.audit.insert(op("b", recent + 310))                      // haiku: the session switched
        try store.audit.insert(op("c", recent + 10, session: "c1", source: .codex))
        // Same session id under another source is another session
        try store.audit.insert(op("d", recent + 10, session: "c1"))
        try store.audit.insert(op("old", now.timeIntervalSince1970 - 200_000, session: "gone"))
        try store.audit.insert(op("fresh", now.timeIntervalSince1970 - 30))  // usage not scanned yet
        let days = try store.audit.dayFingerprints()

        let step = try AuditModelAttributor.step(store: store, now: now)
        try expectEqual(step.examined, 5)   // "fresh" is younger than the settle delay
        try expectEqual(step.settled, 4)
        let models = Dictionary(uniqueKeysWithValues: try store.audit.recent(limit: 10).map { ($0.opId, $0.model) })
        try expectEqual(models["a"] ?? nil, "opus")
        try expectEqual(models["b"] ?? nil, "haiku")
        try expectEqual(models["c"] ?? nil, "gpt")
        try expect((models["d"] ?? nil) == nil, "一天内对不上的留着")
        try expectEqual(models["old"] ?? nil, "")
        try expect((models["fresh"] ?? nil) == nil)
        try expectEqual(try store.audit.dayFingerprints(), days)
        // Nothing new to settle on the next pass
        try expectEqual(try AuditModelAttributor.step(store: store, now: now).settled, 0)
    }

    t.test("分组：每组的操作数、各类占比、风险与失败；未归属单独成组") {
        let (store, path) = try tempStore()
        defer { try? FileManager.default.removeItem(at: path) }
        let pipeline = AuditPipeline(store: store)
        let day1 = 1_700_000_000.0
        try pipeline.ingest(op("1", day1, detail: "ls"), isStale: true)
        try pipeline.ingest(op("2", day1 + 1, detail: "cat .env"), isStale: true)             // critical
        try pipeline.ingest(op("3", day1 + 2, kind: .edit, tool: "Edit", detail: "/Users/me/repo/a.swift"), isStale: true)
        try pipeline.ingest(op("4", day1 + 3, detail: "git push origin main", error: true), isStale: true)  // notice
        try pipeline.ingest(op("5", day1 + 86_400, session: "s2", detail: "ls", cwd: "/Users/me/other"), isStale: true)
        try store.audit.setModels([(1, "opus"), (2, "opus"), (3, "opus"), (4, "haiku")])

        let analytics = try AuditAnalyticsBuilder.build(
            store: store, query: AuditRepo.Query(), dimension: .model, home: "/Users/me")
        try expectEqual(analytics.groups.map(\.key), ["opus", "haiku", ""])
        let opus = analytics.groups[0]
        try expectEqual(opus.total, 3)
        try expectEqual(opus.byKind, [.command: 2, .edit: 1])
        try expectEqual(opus.risk, 1)
        try expectEqual(opus.high, 1)
        try expectEqual(opus.riskByCategory, [.credentials: 1])
        let haiku = analytics.groups[1]
        try expectEqual(haiku.errors, 1)
        try expectEqual(haiku.riskByCategory, [.versionControl: 1])
        try expectEqual(haiku.high, 0)
        try expectEqual(analytics.totals.total, 5)
        try expectEqual(analytics.totals.risk, 2)
        try expectEqual(analytics.days.map(\.total), [4, 1])
        try expectEqual(analytics.days[0].risk, 2)
        try expectEqual(Set(analytics.rules.map(\.label)), ["read-env-file", "git-push-main"])

        // Other dimensions, and the filters the page passes
        let byProject = try AuditAnalyticsBuilder.build(
            store: store, query: AuditRepo.Query(), dimension: .project, home: "/Users/me")
        try expectEqual(byProject.groups.map(\.key), ["/Users/me/repo", "/Users/me/other"])
        try expectEqual(try store.audit.count(.init(model: "opus")), 3)
        try expectEqual(try store.audit.count(.init(model: "")), 1)
        try expectEqual(try store.audit.count(.init(project: "/Users/me/repo")), 4)
        try expectEqual(try store.audit.count(.init(project: "/Users/me")), 5)
        try expectEqual(try store.audit.count(.init(project: "/Users/me/rep")), 0, "前缀要落在目录边界上")
        try expectEqual(try store.audit.count(.init(
            from: Date(timeIntervalSince1970: day1 + 2), to: Date(timeIntervalSince1970: day1 + 4))), 2)
    }

    t.test("排行：命令词、域名、目录") {
        let ranked = AuditAnalyticsBuilder.rankCommands([
            "cd repo && git status | head -3",
            "curl -s https://api.github.com/repos/a/b | jq .name",
            #"TOKEN=$(gcloud auth print-access-token); curl -H "Authorization: Bearer $TOKEN" https://monitoring.googleapis.com/v3/x"#,
        ])
        try expectEqual(ranked.commands["git"], 1)
        try expectEqual(ranked.commands["curl"], 2)
        try expectEqual(ranked.commands["gcloud"], 1)
        try expectEqual(ranked.hosts, ["api.github.com": 1, "monitoring.googleapis.com": 1])
        try expectEqual(AuditAnalyticsBuilder.host(of: "https://user:pw@Example.com:8443/a?b=1"), "example.com")
        try expectEqual(AuditAnalyticsBuilder.host(of: "http://localhost:3000/x"), "localhost")
        try expect(AuditAnalyticsBuilder.host(of: "swift concurrency actors") == nil)
        try expect(AuditAnalyticsBuilder.host(of: "https://$HOST/x") == nil)
        try expectEqual(AuditAnalyticsBuilder.directory(of: "/Users/me/repo/src/a.swift", home: "/Users/me"), "~/repo/src")
        try expectEqual(AuditAnalyticsBuilder.directory(of: "/Users/me/a.txt", home: "/Users/me"), "~")
        try expectEqual(AuditAnalyticsBuilder.directory(of: "/etc/hosts", home: "/Users/me"), "/etc")
        try expectEqual(AuditAnalyticsBuilder.directory(of: "a.swift", home: "/Users/me"), ".")
    }
}
