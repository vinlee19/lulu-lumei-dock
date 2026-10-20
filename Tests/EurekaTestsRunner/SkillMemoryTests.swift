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

    t.test("frontmatter description 为 | / > 块标量时取正文并折成一行，不返回字面 |") {
        let text = """
        ---
        name: kimi-webbridge
        description: |
          Kimi WebBridge lets AI control
          the user's real browser.
        allowed-tools: Bash
        ---
        """
        let parsed = SkillMemoryIndexer.parseFrontmatter(text)
        try expectEqual(parsed.name, "kimi-webbridge")
        try expectEqual(parsed.description, "Kimi WebBridge lets AI control the user's real browser.")
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
        try writeSkill(codexSkills, dir: "gamma", body: "# 无 yaml\n")  // falls back to the directory name

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

    t.test("项目根与系统根重合 → 按 path 去重，只留系统级一条") {
        // Reproduces a real bug: when a session ran in ~, the repo root fell back to home and
        // ~/.claude/skills was scanned again as "project level", yielding two entries with the same
        // path for one SKILL.md (duplicate ids → grid holes).
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            "eureka-dedupe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }

        let claudeSkills = base.appendingPathComponent("claude-skills", isDirectory: true)
        let codexSkills = base.appendingPathComponent("codex-skills", isDirectory: true)
        try writeSkill(claudeSkills, dir: "alpha", body: "---\nname: Alpha\n---\n")

        let skills = SkillMemoryIndexer.indexSkills(
            claudeSkillsRoot: claudeSkills, codexSkillsRoot: codexSkills,
            // The project root deliberately points at the same system root
            projectSkillRoots: [
                ProjectScopedRoot(root: claudeSkills, source: .claude, projectName: "wl.xiao")
            ])
        try expectEqual(skills.count, 1, "同一 path 只应保留一条")
        try expectEqual(Set(skills.map(\.path)).count, 1, "path 必须唯一（Identifiable id）")
        let alpha = try requireSkill(skills, named: "Alpha")
        try expect(alpha.scope.projectName == nil, "系统级先扫应优先保留，不应被标成项目级")
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

    // Official definition (code.claude.com/docs/en/memory, "Organize rules with .claude/rules/"):
    // both user-level ~/.claude/rules/ and project-level <repo>/.claude/rules/ are persistent
    // instructions, .md files are discovered recursively, and directories support symlinks (sharing
    // one rule set across projects) and must handle cycles.
    t.test("Claude 规则目录：~/.claude/rules 与 <repo>/.claude/rules 递归收 .md 为指令，跟随符号链接且防环") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("eureka-claude-rules-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        func write(_ text: String, to url: URL) throws {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let claudeHome = base.appendingPathComponent("claude", isDirectory: true)
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        // User level: flat + subdirectory; non-.md files are not collected
        try write("- 2 空格缩进\n", to: claudeHome.appendingPathComponent("rules/preferences.md"))
        try write("- 先 rebase 再 push\n", to: claudeHome.appendingPathComponent("rules/workflows/git.md"))
        try write("scratch", to: claudeHome.appendingPathComponent("rules/notes.txt"))
        // Project level: a path rule with paths: frontmatter + subdirectory
        try write("---\npaths:\n  - \"src/api/**/*.ts\"\n---\n\n# API 规则\n",
                  to: repo.appendingPathComponent(".claude/rules/testing.md"))
        try write("# 样式\n", to: repo.appendingPathComponent(".claude/rules/frontend/style.md"))
        // A shared rules directory is symlinked into the project; inside it, a cycle pointing back
        // at itself
        let shared = base.appendingPathComponent("shared-rules", isDirectory: true)
        try write("# 安全\n", to: shared.appendingPathComponent("security.md"))
        try fm.createSymbolicLink(
            at: shared.appendingPathComponent("loop"), withDestinationURL: shared)
        try fm.createSymbolicLink(
            at: repo.appendingPathComponent(".claude/rules/shared"), withDestinationURL: shared)

        let entries = SkillMemoryIndexer.indexMemory(
            claudeHome: claudeHome,
            codexHome: base.appendingPathComponent("nope"),
            opencodeHome: base.appendingPathComponent("nope"),
            claudeProjectsRoot: base.appendingPathComponent("nope"),
            projectRoots: [(root: repo, name: "repo")]
        ).filter { $0.source == .claude }
        try expect(entries.allSatisfy { $0.kind == .instructions }, "规则文件全部是指令，不是记忆")
        let global = entries.filter { $0.projectName == nil }
        try expectEqual(
            Set(global.map(\.scope)), ["preferences", "workflows/git"],
            "用户级规则 scope = rules 内相对路径；实得 \(global.map(\.scope))")
        let project = entries.filter { $0.projectName == "repo" }
        try expectEqual(
            Set(project.map(\.scope)), ["testing", "frontend/style", "shared/security"],
            "项目级规则含符号链接目录里的文件；实得 \(project.map(\.scope))")
        try expectEqual(project.count, 3, "环不得产出重复条目")
    }

    t.test("Codex 记忆语义：override 优先、目录链指令可见、生成 memory 只读") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("eureka-codex-memory-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let codexHome = base.appendingPathComponent("codex", isDirectory: true)
        let generatedDir = codexHome.appendingPathComponent("memories", isDirectory: true)
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        let nested = repo.appendingPathComponent("Sources/Feature", isDirectory: true)
        try fm.createDirectory(at: generatedDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try "# 标准全局".write(
            to: codexHome.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "# 覆盖全局".write(
            to: codexHome.appendingPathComponent("AGENTS.override.md"), atomically: true, encoding: .utf8)
        try "# generated".write(
            to: generatedDir.appendingPathComponent("raw_memories.md"),
            atomically: true, encoding: .utf8)
        try "# 项目标准".write(
            to: repo.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "# 项目覆盖".write(
            to: repo.appendingPathComponent("AGENTS.override.md"), atomically: true, encoding: .utf8)
        try "# 深层指令".write(
            to: nested.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let memories = SkillMemoryIndexer.indexMemory(
            claudeHome: base.appendingPathComponent("claude", isDirectory: true),
            codexHome: codexHome,
            opencodeHome: base.appendingPathComponent("opencode", isDirectory: true),
            claudeProjectsRoot: base.appendingPathComponent("projects", isDirectory: true),
            projectRoots: [(root: repo, name: "repo")],
            codexInstructionScopes: [
                (directory: repo, projectName: "repo", scope: "repo"),
                (directory: repo.appendingPathComponent("Sources"),
                 projectName: "repo", scope: "repo/Sources"),
                (directory: nested, projectName: "repo", scope: "repo/Sources/Feature"),
            ])

        let codex = memories.filter { $0.source == .codex }
        try expect(codex.contains {
            $0.path.hasSuffix("codex/AGENTS.override.md") && $0.kind == .instructions
                && $0.isEditable && $0.isDeletable
        }, "全局 override 应作为有效指令")
        try expect(!codex.contains { $0.path.hasSuffix("codex/AGENTS.md") },
                   "同级存在 override 时不应重复展示 AGENTS.md")
        try expect(codex.contains {
            $0.path.hasSuffix("repo/AGENTS.override.md") && $0.scope == "repo"
        }, "项目根 override 应优先")
        try expect(!codex.contains { $0.path.hasSuffix("repo/AGENTS.md") },
                   "项目根标准指令应被 override 遮蔽")
        try expect(codex.contains {
            $0.path.hasSuffix("Sources/Feature/AGENTS.md")
                && $0.scope == "repo/Sources/Feature" && $0.kind == .instructions
        }, "近期 cwd 的嵌套指令应可见")
        guard let generated = codex.first(where: { $0.kind == .generated }) else {
            throw ExpectationError(description: "缺 Codex 生成 memory")
        }
        try expect(generated.path.hasSuffix("memories/raw_memories.md"))
        try expect(!generated.isEditable && !generated.isDeletable,
                   "Codex 后台生成 memory 必须只读且不可删除")
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

    t.test("kimi 记忆：全局 AGENTS.md + 项目 .kimi-code/AGENTS.md；opencode memories 目录") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("eureka-kimimen-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let kimiHome = base.appendingPathComponent("kimi-code", isDirectory: true)
        let opencodeHome = base.appendingPathComponent("opencode", isDirectory: true)
        let repo = base.appendingPathComponent("myrepo/.kimi-code", isDirectory: true)
        try fm.createDirectory(at: kimiHome, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: opencodeHome.appendingPathComponent("memories"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try "# 全局".write(
            to: kimiHome.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "# 项目".write(
            to: repo.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "oc note".write(
            to: opencodeHome.appendingPathComponent("memories/oc.md"),
            atomically: true, encoding: .utf8)

        let memories = SkillMemoryIndexer.indexMemory(
            claudeHome: base.appendingPathComponent("c", isDirectory: true),
            codexHome: base.appendingPathComponent("x", isDirectory: true),
            opencodeHome: opencodeHome,
            claudeProjectsRoot: base.appendingPathComponent("p", isDirectory: true),
            kimiHome: kimiHome,
            projectRoots: [(root: repo.deletingLastPathComponent(), name: "myrepo")])
        try expect(memories.contains {
            $0.source == .kimi && $0.scope == "全局" && $0.projectName == nil
        }, "缺 kimi 全局 AGENTS.md")
        try expect(memories.contains {
            $0.source == .kimi && $0.projectName == "myrepo"
        }, "缺项目 .kimi-code/AGENTS.md")
        try expect(memories.contains {
            $0.source == .opencode && $0.scope == "oc"
        }, "缺 opencode memories/oc.md（死路径修复）")
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

    t.test("kimi 技能根：source .kimi、系统级、含停用区") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("eureka-kimiskill-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let kimiSkills = base.appendingPathComponent("kimi-skills", isDirectory: true)
        try writeSkill(kimiSkills, dir: "ks", body: "---\nname: KimiSkill\n---\n")
        try writeSkill(
            SkillMemoryIndexer.disabledRoot(for: kimiSkills),
            dir: "koff", body: "---\nname: KimiOff\n---\n")

        let skills = SkillMemoryIndexer.indexSkills(
            claudeSkillsRoot: base.appendingPathComponent("c", isDirectory: true),
            codexSkillsRoot: base.appendingPathComponent("x", isDirectory: true),
            kimiSkillsRoot: kimiSkills)
        let active = try requireSkill(skills, named: "KimiSkill")
        try expect(active.source == .kimi && active.enabled && active.scope == .system)
        let disabled = try requireSkill(skills, named: "KimiOff")
        try expect(disabled.source == .kimi && !disabled.enabled)
    }

    t.test("normalizeSkillName：plugin:skill 取冒号后段、小写") {
        try expectEqual(
            SkillMemoryIndexer.normalizeSkillName("superpowers:Brainstorming"), "brainstorming")
        try expectEqual(SkillMemoryIndexer.normalizeSkillName("Code-Review"), "code-review")
    }

    // MARK: - memory library (Claude projects/<encoded>/memory)

    t.test("目录名编码：/ 与 . 与 _ 全变 -（实勘 11 个目录的规则）") {
        // Observed case: the underscores in metric_flow / test_parameter are also - in the
        // directory name
        try expectEqual(
            SkillMemoryIndexer.encodeProjectDirName(
                "/Users/x/w/metricflow-ci/metric_flow/models/test_parameter"),
            "-Users-x-w-metricflow-ci-metric-flow-models-test-parameter")
        try expectEqual(
            SkillMemoryIndexer.encodeProjectDirName("/Users/x/w/repo/.worktrees/feat"),
            "-Users-x-w-repo--worktrees-feat")
    }

    t.test("wiki 链接采集：去重、跨行不算、超长不算") {
        let text = """
        正文引用 [[project_alpha]] 与 [[feedback-beta]]，再引用一次 [[project_alpha]]。
        强调号误用 [[这是一段
        跨行文本]] 不该算链接。
        """
        let links = SkillMemoryIndexer.extractWikiLinks(text)
        try expectEqual(links, ["project_alpha", "feedback-beta"])
    }

    t.test("项目记忆库：frontmatter/链接/来源会话/索引 全部落库，项目名不再被切成末段") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            "eureka-memlib-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }

        // The repo root deliberately contains hyphens: the old friendlyProject would cut it down to
        // "layer"
        let repo = base.appendingPathComponent("w/aftership-semantic-layer", isDirectory: true)
        let encoded = SkillMemoryIndexer.encodeProjectDirName(repo.standardizedFileURL.path)
        let projects = base.appendingPathComponent("projects", isDirectory: true)
        let projectDir = projects.appendingPathComponent(encoded, isDirectory: true)
        let memory = projectDir.appendingPathComponent("memory", isDirectory: true)
        try fm.createDirectory(at: memory, withIntermediateDirectories: true)

        try "# Memory Index\n- [feedback_push.md](feedback_push.md) — 钩子\n"
            .write(to: memory.appendingPathComponent("MEMORY.md"),
                   atomically: true, encoding: .utf8)
        // References another entry in the same library (underscore file name ↔ hyphenated name must
        // match) + one unresolvable link
        try """
        ---
        name: feedback-push-to-origin
        description: push 只推 origin
        metadata:
          node_type: memory
          type: feedback
          originSessionId: 11111111-2222-3333-4444-555555555555
        ---

        正文引用 [[project_alpha]]，以及 [[根本不存在的目标]]。
        """.write(to: memory.appendingPathComponent("feedback_push.md"),
                  atomically: true, encoding: .utf8)
        try """
        ---
        name: project-alpha
        description: 项目进展
        metadata:
          type: project
          originSessionId: 99999999-8888-7777-6666-555555555555
        ---

        回指 [[feedback_push]]。
        """.write(to: memory.appendingPathComponent("project_alpha.md"),
                  atomically: true, encoding: .utf8)
        // Leave a session transcript only for the first memory: the other one's origin session
        // counts as deleted
        try "{\"type\":\"user\",\"cwd\":\"\(repo.path)\"}\n".write(
            to: projectDir.appendingPathComponent(
                "11111111-2222-3333-4444-555555555555.jsonl"),
            atomically: true, encoding: .utf8)

        let entries = SkillMemoryIndexer.indexMemory(
            claudeHome: base.appendingPathComponent("claude-home", isDirectory: true),
            codexHome: base.appendingPathComponent("codex-home", isDirectory: true),
            opencodeHome: base.appendingPathComponent("oc-home", isDirectory: true),
            claudeProjectsRoot: projects,
            projectRoots: [(root: repo, name: "aftership-semantic-layer")])

        try expectEqual(entries.count, 3)
        try expect(entries.allSatisfy { $0.libraryKey == "claude:\(encoded)" })
        try expect(
            entries.allSatisfy { $0.projectName == "aftership-semantic-layer" },
            "项目名必须靠正向编码反查出来，不能是被 - 切出来的末段")

        let index = try requireMemory(entries, title: "MEMORY")
        try expect(index.isIndex, "记忆库里的 MEMORY.md 应标成索引")

        let push = try requireMemory(entries, title: "feedback-push-to-origin")
        try expect(!push.isIndex)
        try expectEqual(push.summary, "push 只推 origin")
        try expectEqual(push.memoryType, .feedback)
        try expectEqual(push.originSessionId, "11111111-2222-3333-4444-555555555555")
        try expect(push.originSessionPath != nil, "同目录有 jsonl → 来源会话可跳转")
        try expectEqual(push.links.count, 2)

        let alpha = try requireMemory(entries, title: "project-alpha")
        try expectEqual(alpha.memoryType, .project)
        try expect(
            alpha.originSessionPath == nil,
            "会话记录文件不在时 originSessionPath 必须是 nil（UI 据此置灰）")

        // Grouping: 2 entries + 1 index, 1 navigable session
        let libraries = MemoryLibrary.group(entries)
        try expectEqual(libraries.count, 1)
        let library = libraries[0]
        try expectEqual(library.count, 2)
        try expect(library.index != nil)
        try expectEqual(library.projectName, "aftership-semantic-layer")
        try expectEqual(library.linkedSessionCount, 1)
        try expectEqual(library.typeBreakdown[.feedback], 1)
        try expectEqual(library.typeBreakdown[.project], 1)
        try expect(library.allFiles.count == 3)
    }

    t.test("Codex 记忆只收 memories/ 顶层：会话摘要/扩展/技能都不是记忆") {
        // Reproduces the real shape: ~/.codex/memories is a git repo mixing
        //   three top-level memories + rollout_summaries/ (session summaries) + extensions/
        //   (meta-instructions) + skills/ (skills)
        // A recursive scan would count all 20 files as memories, 17 of which are not.
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            "eureka-codexmem-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }

        let codexHome = base.appendingPathComponent("codex", isDirectory: true)
        let memories = codexHome.appendingPathComponent("memories", isDirectory: true)
        for sub in ["rollout_summaries", "extensions/ad_hoc", "skills/publish-draft-pr"] {
            try fm.createDirectory(
                at: memories.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
        }
        for name in ["MEMORY.md", "raw_memories.md", "memory_summary.md"] {
            try "记忆".write(
                to: memories.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "会话摘要".write(
            to: memories.appendingPathComponent(
                "rollout_summaries/2026-07-28T08-28-57-FDKv-query_history_plan.md"),
            atomically: true, encoding: .utf8)
        try "元指令".write(
            to: memories.appendingPathComponent("extensions/ad_hoc/instructions.md"),
            atomically: true, encoding: .utf8)
        try "---\nname: publish-draft-pr\n---\n".write(
            to: memories.appendingPathComponent("skills/publish-draft-pr/SKILL.md"),
            atomically: true, encoding: .utf8)

        let entries = SkillMemoryIndexer.indexMemory(
            claudeHome: base.appendingPathComponent("claude", isDirectory: true),
            codexHome: codexHome,
            opencodeHome: base.appendingPathComponent("oc", isDirectory: true),
            claudeProjectsRoot: base.appendingPathComponent("projects", isDirectory: true))
        let codexMemories = entries.filter { $0.source == .codex }
        try expectEqual(
            codexMemories.map(\.title).sorted(), ["MEMORY", "memory_summary", "raw_memories"])
        try expect(
            codexMemories.allSatisfy { $0.kind == .generated },
            "Codex memories 由后台维护 → 只读")

        // That SKILL.md should be picked up by the skill scan (otherwise it is neither a memory nor
        // managed by anything)
        let skills = SkillMemoryIndexer.indexSkills(
            claudeSkillsRoot: base.appendingPathComponent("claude/skills", isDirectory: true),
            codexSkillsRoot: codexHome.appendingPathComponent("skills", isDirectory: true),
            codexMemorySkillsRoot: memories.appendingPathComponent("skills", isDirectory: true))
        try expectEqual(skills.map(\.name), ["publish-draft-pr"])
        try expectEqual(skills.first?.source, .codex)
    }

    t.test("Hermes：MEMORY/USER 是 agent 自记 → 记忆；SOUL 是人格设定 → 指令") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            "eureka-hermes-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let hermes = base.appendingPathComponent("hermes", isDirectory: true)
        try fm.createDirectory(
            at: hermes.appendingPathComponent("memories", isDirectory: true),
            withIntermediateDirectories: true)
        for (path, body) in [
            ("memories/MEMORY.md", "自记"), ("memories/USER.md", "画像"), ("SOUL.md", "人格"),
        ] {
            try body.write(
                to: hermes.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let entries = SkillMemoryIndexer.indexMemory(
            claudeHome: base.appendingPathComponent("claude", isDirectory: true),
            codexHome: base.appendingPathComponent("codex", isDirectory: true),
            opencodeHome: base.appendingPathComponent("oc", isDirectory: true),
            claudeProjectsRoot: base.appendingPathComponent("projects", isDirectory: true),
            hermesHome: hermes)
        let byScope = Dictionary(
            uniqueKeysWithValues: entries.filter { $0.source == .hermes }.map { ($0.scope, $0.kind) })
        try expectEqual(byScope["MEMORY"], .userManaged)
        try expectEqual(byScope["USER"], .userManaged)
        try expectEqual(byScope["SOUL"], .instructions)
    }

    t.test("记忆库索引漂移：未被 MEMORY.md 收录的条目 / 指向空气的引用") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            "eureka-drift-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let projects = base.appendingPathComponent("projects", isDirectory: true)
        let memory = projects
            .appendingPathComponent("-Users-me-w-demo", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        try fm.createDirectory(at: memory, withIntermediateDirectories: true)

        // The index includes a (underscore file name) and b (frontmatter-name form), plus a
        // long-deleted gone
        try """
        # Memory Index

        - [记忆 A](feedback_a.md) — 钩子
        - [project-b](project_b.md) — 钩子
        - [已删掉的](feedback_gone.md) — 钩子
        """.write(to: memory.appendingPathComponent("MEMORY.md"),
                  atomically: true, encoding: .utf8)
        try "---\nname: feedback-a\n---\nA".write(
            to: memory.appendingPathComponent("feedback_a.md"), atomically: true, encoding: .utf8)
        try "---\nname: project-b\n---\nB".write(
            to: memory.appendingPathComponent("project_b.md"), atomically: true, encoding: .utf8)
        // File exists but the index doesn't list it → dead memory
        try "---\nname: orphan-note\n---\nC".write(
            to: memory.appendingPathComponent("orphan_note.md"), atomically: true, encoding: .utf8)

        let entries = SkillMemoryIndexer.indexMemory(
            claudeHome: base.appendingPathComponent("claude", isDirectory: true),
            codexHome: base.appendingPathComponent("codex", isDirectory: true),
            opencodeHome: base.appendingPathComponent("oc", isDirectory: true),
            claudeProjectsRoot: projects)
        let libraries = MemoryLibrary.group(entries)
        try expectEqual(libraries.count, 1)
        let library = libraries[0]
        try expectEqual(library.count, 3)
        try expectEqual(library.index?.indexedTargets.count, 3)
        // After underscore ↔ hyphen normalization both a and b count as included; only orphan_note
        // is not
        try expectEqual(library.unindexedEntries.map(\.title), ["orphan-note"])
        try expectEqual(library.danglingIndexRefs, ["feedback_gone.md"])
        try expect(library.hasDrift)

        // The graph must mark unincluded entries (the UI draws a dashed line + hint from this)
        let graph = MemoryGraphBuilder.build(library.graphInput())
        let flagged = graph.nodes.filter(\.isUnindexed).map(\.title)
        try expectEqual(flagged, ["orphan-note"])
    }

    t.test("Codex MEMORY.md：从 rollout_summary_files 段落解析出多个来源会话") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            "eureka-cxrefs-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let codexHome = base.appendingPathComponent("codex", isDirectory: true)
        let memories = codexHome.appendingPathComponent("memories", isDirectory: true)
        try fm.createDirectory(at: memories, withIntermediateDirectories: true)
        // One rollout that exists + one that was deleted
        let live = base.appendingPathComponent("rollout-live.jsonl")
        try "{}".write(to: live, atomically: true, encoding: .utf8)
        let gone = base.appendingPathComponent("rollout-gone.jsonl")

        try """
        # Task Group: demo

        applies_to: cwd=/Users/me/w/demo

        ### rollout_summary_files

        - rollout_summaries/a.md (cwd=/Users/me/w/demo, rollout_path=\(live.path), \
        updated_at=2026-07-28T13:49:25+00:00, thread_id=019fa2f0-c124-7c03-a2d1-c6debaf69293, ok)
        - rollout_summaries/b.md (cwd=/Users/me/.slock/agents/xxx, rollout_path=\(gone.path), \
        thread_id=019fa772-b007-75e1-9c97-56eb93b67b43, sandbox cwd 不能用来归项目)
        """.write(to: memories.appendingPathComponent("MEMORY.md"),
                  atomically: true, encoding: .utf8)

        let entries = SkillMemoryIndexer.indexMemory(
            claudeHome: base.appendingPathComponent("claude", isDirectory: true),
            codexHome: codexHome,
            opencodeHome: base.appendingPathComponent("oc", isDirectory: true),
            claudeProjectsRoot: base.appendingPathComponent("projects", isDirectory: true))
        let index = try requireMemory(entries, title: "MEMORY")
        try expectEqual(index.relatedSessions.count, 2)
        try expectEqual(
            index.relatedSessions.map(\.sessionId),
            ["019fa2f0-c124-7c03-a2d1-c6debaf69293", "019fa772-b007-75e1-9c97-56eb93b67b43"])
        try expect(index.relatedSessions[0].exists, "rollout 文件在 → 可跳转")
        try expect(!index.relatedSessions[1].exists, "rollout 文件不在 → 置灰")
    }

    t.test("项目名兜底：目录名对不上已知仓库根时读 jsonl 头部的 cwd") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(
            "eureka-memfallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }

        let projects = base.appendingPathComponent("projects", isDirectory: true)
        let projectDir = projects.appendingPathComponent(
            "-Users-someone-w-my-cool-repo", isDirectory: true)
        let memory = projectDir.appendingPathComponent("memory", isDirectory: true)
        try fm.createDirectory(at: memory, withIntermediateDirectories: true)
        try "记忆".write(
            to: memory.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try "{\"type\":\"user\",\"cwd\":\"/Users/someone/w/my_cool_repo\"}\n".write(
            to: projectDir.appendingPathComponent("abc.jsonl"),
            atomically: true, encoding: .utf8)

        let entries = SkillMemoryIndexer.indexMemory(
            claudeHome: base.appendingPathComponent("claude-home", isDirectory: true),
            codexHome: base.appendingPathComponent("codex-home", isDirectory: true),
            opencodeHome: base.appendingPathComponent("oc-home", isDirectory: true),
            claudeProjectsRoot: projects)
        try expectEqual(entries.count, 1)
        try expectEqual(entries[0].projectName, "my_cool_repo")
        try expectEqual(entries[0].title, "note")
        try expectEqual(entries[0].memoryType, .other)
    }
}

private func writeSkill(_ root: URL, dir: String, body: String) throws {
    let skillDir = root.appendingPathComponent(dir, isDirectory: true)
    try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
    try body.write(
        to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
}

private func requireMemory(_ entries: [MemoryEntry], title: String) throws -> MemoryEntry {
    guard let entry = entries.first(where: { $0.title == title }) else {
        throw ExpectationError(
            description: "未找到记忆 \(title)（实有：\(entries.map(\.title).joined(separator: ", "))）")
    }
    return entry
}

private func requireSkill(_ skills: [SkillEntry], named name: String) throws -> SkillEntry {
    guard let skill = skills.first(where: { $0.name == name }) else {
        throw ExpectationError(description: "未找到技能 \(name)")
    }
    return skill
}
