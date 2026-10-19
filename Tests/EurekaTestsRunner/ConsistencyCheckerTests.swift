import EurekaIngest
import EurekaKit
import Foundation

/// Tests for the consistency check's **criteria**. The biggest risk here is not miscounting but
/// over-reporting -- a card full of noise gets looked at twice and then never again. So every case
/// pins down a boundary where it should **not** report.
func consistencyCheckerTests(_ t: TestRunner) {
    t.suite("ConsistencyChecker · 跨源一致性口径")

    func instruction(_ project: String, _ file: String) -> MemoryEntry {
        MemoryEntry(
            source: file.hasPrefix("CLAUDE") ? .claude : .codex,
            scope: project, path: "/repos/\(project)/\(file)",
            projectName: project, kind: .instructions, sizeBytes: 1, modifiedAt: Date())
    }
    func skill(_ name: String, _ source: AgentSource) -> SkillEntry {
        SkillEntry(
            source: source, name: name, description: nil,
            path: "/skills/\(source.rawValue)/\(name)/SKILL.md",
            directory: "/skills/\(source.rawValue)/\(name)",
            enabled: true, sizeBytes: 1, modifiedAt: Date())
    }

    t.test("指令缺口：只按「用户已在 ≥2 个仓库用过的约定」判，不照理想清单挑刺") {
        // The user configured CLAUDE.md + AGENTS.md in both repos a/b -> those two are their habit;
        // c only has CLAUDE.md -> report AGENTS.md missing. GEMINI.md appears only once, in a ->
        // not a convention, not reported.
        let memories = [
            instruction("a", "CLAUDE.md"), instruction("a", "AGENTS.md"),
            instruction("a", "GEMINI.md"),
            instruction("b", "CLAUDE.md"), instruction("b", "AGENTS.md"),
            instruction("c", "CLAUDE.md"),
        ]
        let report = ConsistencyChecker.report(
            skills: [], memories: memories, libraries: [], repoNames: ["a", "b", "c"])
        try expectEqual(report.instructionGaps.count, 1)
        try expectEqual(report.instructionGaps[0].project, "c")
        try expectEqual(report.instructionGaps[0].missing, ["AGENTS.md"])
        try expect(
            !report.instructionGaps.contains { $0.missing.contains("GEMINI.md") },
            "只在一个仓库出现过的文件不算约定，不能拿它去要求别的仓库")
    }

    t.test("指令缺口：没有记忆库的「仓库」不参与（sandbox 工作目录不是项目）") {
        // ProjectResolver treats sandbox cwds like ~/.slock/agents/<uuid> as repo roots; 5 of the
        // 17 "repos" measured on this machine are like that. They have neither instructions nor a
        // memory library -> they must not flood the gap list.
        let memories = [
            instruction("real-a", "CLAUDE.md"), instruction("real-a", "AGENTS.md"),
            instruction("real-b", "CLAUDE.md"), instruction("real-b", "AGENTS.md"),
        ]
        let libraries = MemoryLibrary.group([
            MemoryEntry(
                source: .claude, scope: "active-no-instruction",
                path: "/p/-repos-active/memory/note.md",
                projectName: "active-no-instruction", sizeBytes: 1, modifiedAt: Date(),
                libraryKey: "claude:-repos-active"),
        ])
        let report = ConsistencyChecker.report(
            skills: [], memories: memories, libraries: libraries,
            repoNames: [
                "real-a", "real-b", "active-no-instruction",
                "c2cac433-5e0f-4379-99db-a867424d8e6f",  // sandbox: no instructions, no memory library
            ])
        try expectEqual(
            report.instructionGaps.map(\.project), ["active-no-instruction"],
            "只有「有记忆库」的无指令仓库才算活跃项目")
    }

    t.test("技能缺口：只报「只差这一个源」的，且源自身技能数够多才参与对账") {
        var skills: [SkillEntry] = []
        // claude / cursor / gemini have 12 skills each -> all meet the threshold (>=10) and take
        // part in reconciliation
        for index in 0..<12 {
            skills.append(skill("shared-\(index)", .claude))
            skills.append(skill("shared-\(index)", .cursor))
            // gemini alone is missing shared-0/1/2
            if index >= 3 { skills.append(skill("shared-\(index)", .gemini)) }
        }
        // Top gemini up to 12 (with skills only it has) so it takes part in reconciliation
        for index in 0..<3 { skills.append(skill("gemini-only-\(index)", .gemini)) }
        // kimi has only 2 skills -> below the threshold, excluded (otherwise it would be "missing"
        // a whole pile)
        skills.append(skill("shared-0", .kimi))
        skills.append(skill("kimi-only", .kimi))

        let report = ConsistencyChecker.report(
            skills: skills, memories: [], libraries: [], repoNames: [])
        try expectEqual(report.skillGaps.count, 1, "只该报 gemini")
        try expectEqual(report.skillGaps[0].source, .gemini)
        try expectEqual(report.skillGaps[0].missing, ["shared-0", "shared-1", "shared-2"])
        try expect(
            !report.skillGaps.contains { $0.source == .kimi },
            "技能太少的源不参与对账，否则它会被报成缺一大堆")
    }

    t.test("技能缺口：两个源同时缺的技能不报（那是故意没同步，不是漏装）") {
        var skills: [SkillEntry] = []
        for index in 0..<12 {
            skills.append(skill("shared-\(index)", .claude))
            skills.append(skill("shared-\(index)", .cursor))
        }
        // gemini and opencode both meet the threshold but both lack shared-0 -> missing from 2
        // sources, not reported
        for index in 1..<12 {
            skills.append(skill("shared-\(index)", .gemini))
            skills.append(skill("shared-\(index)", .opencode))
        }
        let report = ConsistencyChecker.report(
            skills: skills, memories: [], libraries: [], repoNames: [])
        try expect(
            report.skillGaps.isEmpty,
            "多个源同时缺同一技能 ⇒ 大概率是故意的，报了没有可执行动作：\(report.skillGaps)")
    }

    t.test("零问题时 isClean，且不产出任何条目") {
        let memories = [
            instruction("a", "CLAUDE.md"), instruction("a", "AGENTS.md"),
            instruction("b", "CLAUDE.md"), instruction("b", "AGENTS.md"),
        ]
        let report = ConsistencyChecker.report(
            skills: [], memories: memories, libraries: [], repoNames: ["a", "b"])
        try expect(report.isClean)
        try expectEqual(report.issueCount, 0)
    }
}

func mcpDriftTests(_ t: TestRunner) {
    t.suite("ConsistencyChecker.mcpDrifts（MCP 同名异义）")

    func entry(
        _ source: AgentSource, _ name: String,
        command: String? = nil, url: String? = nil
    ) -> MCPServerEntry {
        MCPServerEntry(
            source: source, name: name,
            transport: url == nil ? "stdio" : "http",
            commandSummary: command, urlSummary: url,
            envKeys: [], projectName: nil, configPath: "/tmp/\(source.rawValue)")
    }

    t.test("同名不同定义 → 漂移；同名同定义 / 单源 → 不报") {
        let servers = [
            // notion: codex remote vs grok local (a case found in the wild) -> drift
            entry(.codex, "notion", url: "https://mcp.notion.com/mcp"),
            entry(.grok, "notion", command: "npx -y @notionhq/notion-mcp-server"),
            // xhawk: same definition in both sources -> not reported
            entry(.cursor, "xhawk", url: "https://app.xhawk.ai/api/mcp"),
            entry(.gemini, "xhawk", url: "https://app.xhawk.ai/api/mcp"),
            // Single source -> not reported
            entry(.claude, "solo", command: "npx solo"),
        ]
        let drifts = ConsistencyChecker.mcpDrifts(servers)
        try expectEqual(drifts.map(\.name), ["notion"])
        try expectEqual(drifts.first?.variants.count, 2)
    }

    t.test("大小写归一：Notion 与 notion 算同名") {
        let drifts = ConsistencyChecker.mcpDrifts([
            entry(.codex, "Notion", url: "https://a/mcp"),
            entry(.grok, "notion", command: "npx b"),
        ])
        try expectEqual(drifts.count, 1)
    }
}
