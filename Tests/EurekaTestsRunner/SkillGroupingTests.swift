import EurekaIngest
import EurekaKit
import Foundation

func skillGroupingTests(_ t: TestRunner) {
    t.suite("SkillGrouping")

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func skill(
        _ source: AgentSource, _ name: String, dir: String? = nil, enabled: Bool = true,
        project: String? = nil
    ) -> SkillEntry {
        let directory = "/home/\(source.rawValue)/skills/\(dir ?? name)"
        return SkillEntry(
            source: source, name: name, description: "desc \(name)",
            path: directory + "/SKILL.md", directory: directory, enabled: enabled,
            scope: project.map { .project($0) } ?? .system,
            sizeBytes: 100, modifiedAt: now)
    }

    t.test("同名技能跨来源合并成一组，来源去重、启用数正确") {
        let groups = SkillGrouping.groups([
            skill(.claude, "kimi-webbridge"),
            skill(.codex, "kimi-webbridge"),
            skill(.kimi, "kimi-webbridge", enabled: false),
            skill(.claude, "research"),
        ], usage: [:])
        try expectEqual(groups.count, 2)
        try expect(groups.contains { $0.key == "kimi-webbridge" }, "kimi-webbridge group missing")
        let kw = groups.first { $0.key == "kimi-webbridge" }!
        try expectEqual(kw.copies.count, 3)
        try expectEqual(kw.sources, [.claude, .codex, .kimi])
        try expectEqual(kw.enabledCount, 2)
        try expect(!kw.isAllEnabled && !kw.isAllDisabled)
        // Enabled copies come first so the primary is a live one.
        try expectEqual(kw.primary.source, .claude)
        try expect(kw.contains(path: "/home/kimi/skills/kimi-webbridge/SKILL.md"))
    }

    t.test("plugin: 前缀按归一化名并入同一组") {
        let groups = SkillGrouping.groups([
            skill(.claude, "plugin:research", dir: "research"),
            skill(.hermes, "research"),
        ], usage: [:])
        try expectEqual(groups.count, 1)
        try expectEqual(groups[0].key, "research")
    }

    t.test("项目标签：全部副本同一项目才有，全局 + 项目混合为空") {
        let onlyProject = SkillGrouping.groups([
            skill(.claude, "regression-replay", project: "aftership-semantic-layer"),
        ], usage: [:])
        try expectEqual(onlyProject[0].projectName, "aftership-semantic-layer")
        let mixed = SkillGrouping.groups([
            skill(.claude, "metricflow-troubleshooting"),
            skill(.claude, "metricflow-troubleshooting", dir: "metricflow-troubleshooting-2",
                  project: "aftership-semantic-layer"),
        ], usage: [:])
        try expectEqual(mixed.count, 1)
        try expectEqual(mixed[0].projectName, nil)
        try expectEqual(mixed[0].copies.count, 2)
        // System scope sorts before the project copy.
        try expectEqual(mixed[0].primary.scope.projectName, nil)
    }

    t.test("用量按来源 + 归一化名匹配，退回目录名；组内求和、取最近一次") {
        let usage: [String: SkillUsage] = [
            SkillGrouping.usageKey(source: .claude, name: "writing-notion-docs"):
                SkillUsage(count: 20, lastTs: now.addingTimeInterval(-86_400)),
            // Recorded under the directory name, not the frontmatter name.
            SkillGrouping.usageKey(source: .codex, name: "notion-docs"):
                SkillUsage(count: 3, lastTs: now.addingTimeInterval(-3_600)),
        ]
        let groups = SkillGrouping.groups([
            skill(.claude, "writing-notion-docs"),
            skill(.codex, "writing-notion-docs", dir: "notion-docs"),
        ], usage: usage)
        try expectEqual(groups.count, 1)
        try expectEqual(groups[0].usageCount, 23)
        try expectEqual(groups[0].lastUsedAt, now.addingTimeInterval(-3_600))
    }

    t.test("分组：30 天内用过的按次数降序排常用，其余按名排已启用，全停的排已停用") {
        let usage: [String: SkillUsage] = [
            SkillGrouping.usageKey(source: .claude, name: "b-recent"):
                SkillUsage(count: 5, lastTs: now.addingTimeInterval(-2 * 86_400)),
            SkillGrouping.usageKey(source: .claude, name: "a-recent"):
                SkillUsage(count: 9, lastTs: now.addingTimeInterval(-10 * 86_400)),
            SkillGrouping.usageKey(source: .claude, name: "old"):
                SkillUsage(count: 40, lastTs: now.addingTimeInterval(-45 * 86_400)),
        ]
        let groups = SkillGrouping.groups([
            skill(.claude, "b-recent"),
            skill(.claude, "a-recent"),
            skill(.claude, "old"),
            skill(.claude, "zeta"),
            skill(.claude, "alpha"),
            skill(.hermes, "off", enabled: false),
        ], usage: usage)
        let sections = SkillGrouping.sections(groups, now: now)
        try expectEqual(sections.map(\.kind), [.frequent, .enabled, .disabled])
        try expectEqual(sections[0].groups.map(\.name), ["a-recent", "b-recent"])
        try expectEqual(sections[1].groups.map(\.name), ["alpha", "old", "zeta"])
        try expectEqual(sections[2].groups.map(\.name), ["off"])
    }

    t.test("空分组不出现；全停用的即使最近用过也不进常用") {
        let usage: [String: SkillUsage] = [
            SkillGrouping.usageKey(source: .claude, name: "ghost"):
                SkillUsage(count: 2, lastTs: now.addingTimeInterval(-86_400)),
        ]
        let sections = SkillGrouping.sections(
            SkillGrouping.groups([skill(.claude, "ghost", enabled: false)], usage: usage),
            now: now)
        try expectEqual(sections.map(\.kind), [.disabled])
    }
}
