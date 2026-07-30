import EurekaIngest
import EurekaKit
import Foundation

/// 一致性检查的**口径**测试。
/// 这块最大的风险不是算错，而是报得太多 —— 一张全是噪声的卡，用户看两次就再也不看了。
/// 所以每条用例都在钉一个「**不该**报」的边界。
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
        // 用户在 a/b 两仓库都配了 CLAUDE.md + AGENTS.md → 这两种是他的习惯；
        // c 只有 CLAUDE.md → 报缺 AGENTS.md。GEMINI.md 只在 a 出现过一次 → 不算约定，不报。
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
        // ProjectResolver 会把 ~/.slock/agents/<uuid> 这类 sandbox cwd 认成仓库根，
        // 本机实测 17 个"仓库"里有 5 个如此。它们既无指令也无记忆库 → 不该刷缺口。
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
                "c2cac433-5e0f-4379-99db-a867424d8e6f",  // sandbox：无指令无记忆库
            ])
        try expectEqual(
            report.instructionGaps.map(\.project), ["active-no-instruction"],
            "只有「有记忆库」的无指令仓库才算活跃项目")
    }

    t.test("技能缺口：只报「只差这一个源」的，且源自身技能数够多才参与对账") {
        var skills: [SkillEntry] = []
        // claude / cursor / gemini 各 12 个技能 → 都够门槛（≥10）参与对账
        for index in 0..<12 {
            skills.append(skill("shared-\(index)", .claude))
            skills.append(skill("shared-\(index)", .cursor))
            // gemini 独独缺 shared-0/1/2 三个
            if index >= 3 { skills.append(skill("shared-\(index)", .gemini)) }
        }
        // gemini 补到 12 个（用它自己独有的技能），保证它参与对账
        for index in 0..<3 { skills.append(skill("gemini-only-\(index)", .gemini)) }
        // kimi 只有 2 个技能 → 门槛不够，不参与（否则它会"缺"一大堆）
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
        // gemini 与 opencode 都够门槛，但都缺 shared-0 → 缺 2 个源，不报
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
