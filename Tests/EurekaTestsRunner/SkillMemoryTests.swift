import EurekaIngest
import EurekaKit
import Foundation

func skillMemoryIndexerTests(_ t: TestRunner) {
    t.suite("SkillMemoryIndexer")

    t.test("frontmatter 解析 name/description（去引号、止于结束 ---）") {
        let text = """
        ---
        name: writing-commits
        description: "Use when writing a commit"
        ---
        # body
        name: not-this
        """
        let parsed = SkillMemoryIndexer.parseFrontmatter(text)
        try expectEqual(parsed.name, "writing-commits")
        try expectEqual(parsed.description, "Use when writing a commit")
    }

    t.test("无 frontmatter → name/description 皆 nil") {
        let parsed = SkillMemoryIndexer.parseFrontmatter("# 只是 markdown\n没有 yaml")
        try expect(parsed.name == nil && parsed.description == nil)
    }

    t.test("技能扫描：启用区 enabled、停用区 disabled、缺 name 退目录名") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("eureka-skilltest", isDirectory: true)
        try? fm.removeItem(at: base)
        defer { try? fm.removeItem(at: base) }

        let claudeSkills = base.appendingPathComponent("claude-skills", isDirectory: true)
        let claudeDisabled = SkillMemoryIndexer.disabledRoot(for: claudeSkills)
        let codexSkills = base.appendingPathComponent("codex-skills", isDirectory: true)
        try writeSkill(claudeSkills, dir: "alpha", body: "---\nname: Alpha\ndescription: 甲\n---\n")
        try writeSkill(claudeDisabled, dir: "beta", body: "---\nname: Beta\n---\n")
        try writeSkill(codexSkills, dir: "gamma", body: "# 无 yaml\n")  // 退目录名

        let skills = SkillMemoryIndexer.indexSkills(
            claudeSkillsRoot: claudeSkills, codexSkillsRoot: codexSkills)
        try expectEqual(skills.count, 3)

        let alpha = try requireSkill(skills, named: "Alpha")
        try expect(alpha.enabled && alpha.source == .claude)
        try expectEqual(alpha.description, "甲")
        let beta = try requireSkill(skills, named: "Beta")
        try expect(!beta.enabled, "停用区技能应 enabled=false")
        let gamma = try requireSkill(skills, named: "gamma")
        try expect(gamma.enabled && gamma.source == .codex)
    }

    t.test("记忆扫描：CLAUDE.md 全局 + memories 目录 + Codex AGENTS.md") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("eureka-memtest", isDirectory: true)
        try? fm.removeItem(at: base)
        defer { try? fm.removeItem(at: base) }

        let claudeHome = base.appendingPathComponent("claude", isDirectory: true)
        let codexHome = base.appendingPathComponent("codex", isDirectory: true)
        let projects = base.appendingPathComponent("projects", isDirectory: true)
        try fm.createDirectory(
            at: claudeHome.appendingPathComponent("memories"), withIntermediateDirectories: true)
        try fm.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)
        try "# 全局".write(
            to: claudeHome.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "note".write(
            to: claudeHome.appendingPathComponent("memories/note.md"), atomically: true, encoding: .utf8)
        try "# agents".write(
            to: codexHome.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let memories = SkillMemoryIndexer.indexMemory(
            claudeHome: claudeHome, codexHome: codexHome,
            opencodeHome: base.appendingPathComponent("opencode", isDirectory: true),
            claudeProjectsRoot: projects)
        try expect(memories.contains { $0.source == .claude && $0.scope == "全局" }, "缺 Claude 全局")
        try expect(memories.contains { $0.source == .claude && $0.scope == "note" }, "缺 memories/note")
        try expect(memories.contains { $0.source == .codex && $0.scope == "全局" }, "缺 Codex AGENTS.md")
    }

    t.test("记忆三源覆盖：opencode 全局 AGENTS.md + 项目根 CLAUDE.md/AGENTS.md") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("eureka-mem3src", isDirectory: true)
        try? fm.removeItem(at: base)
        defer { try? fm.removeItem(at: base) }

        let claudeHome = base.appendingPathComponent("claude", isDirectory: true)
        let codexHome = base.appendingPathComponent("codex", isDirectory: true)
        let opencodeHome = base.appendingPathComponent("opencode", isDirectory: true)
        let projects = base.appendingPathComponent("projects", isDirectory: true)
        let repo = base.appendingPathComponent("myrepo", isDirectory: true)
        try fm.createDirectory(at: opencodeHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try "# oc".write(
            to: opencodeHome.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "# proj claude".write(
            to: repo.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "# proj agents".write(
            to: repo.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let memories = SkillMemoryIndexer.indexMemory(
            claudeHome: claudeHome, codexHome: codexHome, opencodeHome: opencodeHome,
            claudeProjectsRoot: projects, projectRoots: [(root: repo, name: "myrepo")])
        try expect(memories.contains {
            $0.source == .opencode && $0.scope == "全局" && $0.projectName == nil
        }, "缺 opencode 全局 AGENTS.md（系统级）")
        try expect(memories.contains {
            $0.source == .claude && $0.projectName == "myrepo"
        }, "缺项目根 CLAUDE.md（归 Claude）")
        try expect(memories.contains {
            $0.source == .codex && $0.projectName == "myrepo"
        }, "缺项目根 AGENTS.md（归 Codex）")
    }

    t.test("技能分栏：系统根 → .system，项目根 → .project(项目名)") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("eureka-scopetest", isDirectory: true)
        try? fm.removeItem(at: base)
        defer { try? fm.removeItem(at: base) }

        let claudeSkills = base.appendingPathComponent("claude-skills", isDirectory: true)
        let codexSkills = base.appendingPathComponent("codex-skills", isDirectory: true)
        try writeSkill(claudeSkills, dir: "sys", body: "---\nname: SysSkill\n---\n")
        let projRoot = base.appendingPathComponent("myproj/.claude/skills", isDirectory: true)
        try writeSkill(projRoot, dir: "proj", body: "---\nname: ProjSkill\n---\n")

        let skills = SkillMemoryIndexer.indexSkills(
            claudeSkillsRoot: claudeSkills, codexSkillsRoot: codexSkills,
            projectSkillRoots: [ProjectScopedRoot(
                root: projRoot, source: .claude, projectName: "myproj")])

        let sys = try requireSkill(skills, named: "SysSkill")
        try expect(sys.scope == .system, "系统技能 scope 应为 .system")
        let proj = try requireSkill(skills, named: "ProjSkill")
        try expect(proj.scope == .project("myproj"), "项目技能 scope 应为 .project(myproj)")
        try expect(proj.scope.isProject && proj.scope.projectName == "myproj")
    }

    t.test("opencode 技能根 → source .opencode、系统级") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("eureka-ocskill", isDirectory: true)
        try? fm.removeItem(at: base)
        defer { try? fm.removeItem(at: base) }

        let claudeSkills = base.appendingPathComponent("claude-skills", isDirectory: true)
        let codexSkills = base.appendingPathComponent("codex-skills", isDirectory: true)
        let opencodeSkills = base.appendingPathComponent("opencode-skills", isDirectory: true)
        try writeSkill(opencodeSkills, dir: "ocs", body: "---\nname: OcSkill\ndescription: 甲\n---\n")

        let skills = SkillMemoryIndexer.indexSkills(
            claudeSkillsRoot: claudeSkills, codexSkillsRoot: codexSkills,
            opencodeSkillsRoot: opencodeSkills)
        let entry = try requireSkill(skills, named: "OcSkill")
        try expect(entry.source == .opencode && entry.scope == .system)
    }

    t.test("parseFrontmatterFields：tools/model + block scalar description 不误吞后续键") {
        let text = """
        ---
        name: code-reviewer
        description: |
          审查代码。
          多行说明。
        tools: Read, Grep, Bash
        model: opus
        color: green
        ---
        # body
        """
        let fields = SkillMemoryIndexer.parseFrontmatterFields(text)
        try expectEqual(fields["name"], "code-reviewer")
        try expectEqual(fields["model"], "opus")
        try expectEqual(fields["color"], "green")
        try expectEqual(fields["tools"], "Read, Grep, Bash")
        try expect(fields["description"]?.contains("审查代码") == true, "block scalar 描述应被收编")
    }

    t.test("bundledRoots → origin=.bundled；用户根 → origin=.user") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("eureka-origin-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let userRoot = base.appendingPathComponent("user-skills", isDirectory: true)
        let bundledRoot = base.appendingPathComponent("bundled-skills", isDirectory: true)
        try writeSkill(userRoot, dir: "mine", body: "---\nname: Mine\n---\n")
        try writeSkill(bundledRoot, dir: "carried", body: "---\nname: Carried\n---\n")

        let skills = SkillMemoryIndexer.indexSkills(
            claudeSkillsRoot: userRoot,
            codexSkillsRoot: base.appendingPathComponent("codex-none", isDirectory: true),
            bundledRoots: [(root: bundledRoot, source: .grok)])
        let mine = try requireSkill(skills, named: "Mine")
        try expectEqual(mine.origin, .user)
        let carried = try requireSkill(skills, named: "Carried")
        try expectEqual(carried.origin, .bundled)
        try expectEqual(carried.source, .grok)
    }

    t.test("claudePluginSkillsRoots：cache/<mp>/<plugin>/<ver>/skills 命中") {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("eureka-plughome-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let skillsRoot = home.appendingPathComponent(
            "plugins/cache/mkt/superpowers/5.0.7/skills", isDirectory: true)
        try writeSkill(skillsRoot, dir: "brainstorming", body: "---\nname: brainstorming\n---\n")

        let roots = SkillMemoryIndexer.claudePluginSkillsRoots(
            environment: ["EUREKA_CLAUDE_HOME": home.path])
        try expectEqual(roots.count, 1)
        try expect(roots[0].path.hasSuffix("5.0.7/skills"))
    }

    t.test("normalizeSkillName：plugin:skill 取冒号后段、小写") {
        try expectEqual(
            SkillMemoryIndexer.normalizeSkillName("superpowers:Brainstorming"), "brainstorming")
        try expectEqual(SkillMemoryIndexer.normalizeSkillName("Code-Review"), "code-review")
    }
}

private func writeSkill(_ root: URL, dir: String, body: String) throws {
    let skillDir = root.appendingPathComponent(dir, isDirectory: true)
    try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
    try body.write(
        to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
}

private func requireSkill(_ skills: [SkillEntry], named name: String) throws -> SkillEntry {
    guard let skill = skills.first(where: { $0.name == name }) else {
        throw ExpectationError(description: "未找到技能 \(name)")
    }
    return skill
}
