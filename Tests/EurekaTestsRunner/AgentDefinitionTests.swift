import EurekaIngest
import EurekaKit
import Foundation

func agentDefinitionTests(_ t: TestRunner) {
    t.suite("AgentDefinitionIndexer")

    t.test("扫描 Claude agent：frontmatter tools/model、系统/项目 scope、启用/停用") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("eureka-agenttest", isDirectory: true)
        try? fm.removeItem(at: base)
        defer { try? fm.removeItem(at: base) }

        let systemRoot = base.appendingPathComponent("agents", isDirectory: true)
        let disabled = AgentDefinitionIndexer.disabledRoot(for: systemRoot)
        let projRoot = base.appendingPathComponent("proj/.claude/agents", isDirectory: true)

        try writeAgent(systemRoot, name: "reviewer",
            body: "---\nname: reviewer\ndescription: 审查\ntools: Read, Grep\nmodel: opus\n---\n正文")
        try writeAgent(disabled, name: "old", body: "---\nname: old\n---\n")
        try writeAgent(projRoot, name: "local", body: "---\nname: local\n---\n")

        let agents = AgentDefinitionIndexer.indexClaudeAgents(
            systemRoot: systemRoot,
            projectRoots: [ProjectScopedRoot(root: projRoot, source: .claude, projectName: "proj")])

        try expectEqual(agents.count, 3)
        let reviewer = try requireAgent(agents, named: "reviewer")
        try expect(reviewer.enabled && reviewer.scope == .system)
        try expectEqual(reviewer.model, "opus")
        try expectEqual(reviewer.tools, ["Read", "Grep"])
        try expectEqual(reviewer.description, "审查")
        let old = try requireAgent(agents, named: "old")
        try expect(!old.enabled, "停用区应 enabled=false")
        let local = try requireAgent(agents, named: "local")
        try expect(local.scope == .project("proj"), "项目 agent scope 应为 .project(proj)")
    }

    t.test("tools 解析：[] 与逗号列表、空 → 空数组（继承全部）") {
        try expectEqual(AgentDefinitionIndexer.parseToolList("[Read, Write]"), ["Read", "Write"])
        try expectEqual(AgentDefinitionIndexer.parseToolList("Read, Write"), ["Read", "Write"])
        try expectEqual(AgentDefinitionIndexer.parseToolList(nil), [])
        try expectEqual(AgentDefinitionIndexer.parseToolList(""), [])
    }

    t.test("opencode agent：解析 mode、source .opencode、文件名即 id") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("eureka-ocagent", isDirectory: true)
        try? fm.removeItem(at: base)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("agents", isDirectory: true)
        try writeAgent(root, name: "reviewer",
            body: "---\ndescription: 审查\nmode: subagent\nmodel: glm-5.2\n---\n正文")

        let agents = AgentDefinitionIndexer.indexOpencodeAgents(systemRoots: [root])
        let reviewer = try requireAgent(agents, named: "reviewer")
        try expect(reviewer.source == .opencode)
        try expectEqual(reviewer.mode, "subagent")
        try expectEqual(reviewer.model, "glm-5.2")
        try expectEqual(reviewer.description, "审查")
    }

    t.test("扫描插件 agent：installed_plugins.json → installPath/agents，打 pluginName、含停用区") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("eureka-pluginagent", isDirectory: true)
        try? fm.removeItem(at: base)
        defer { try? fm.removeItem(at: base) }

        let installPath = base.appendingPathComponent("cache/market/myplugin/1.0.0", isDirectory: true)
        let agentsRoot = installPath.appendingPathComponent("agents", isDirectory: true)
        try writeAgent(agentsRoot, name: "reviewer",
            body: "---\nname: reviewer\ndescription: 审查\nmodel: opus\n---\n")
        try writeAgent(AgentDefinitionIndexer.disabledRoot(for: agentsRoot), name: "old",
            body: "---\nname: old\n---\n")

        let json = """
        {"version":2,"plugins":{"myplugin@market":[{"scope":"user","installPath":"\(installPath.path)"}]}}
        """
        try json.write(to: base.appendingPathComponent("installed_plugins.json"),
                       atomically: true, encoding: .utf8)

        let agents = AgentDefinitionIndexer.indexPluginAgents(pluginsRoot: base)
        try expectEqual(agents.count, 2)
        let reviewer = try requireAgent(agents, named: "reviewer")
        try expectEqual(reviewer.pluginName, "myplugin")
        try expect(reviewer.enabled)
        try expectEqual(reviewer.model, "opus")
        let old = try requireAgent(agents, named: "old")
        try expect(!old.enabled, "插件停用区应 enabled=false")
        try expectEqual(old.pluginName, "myplugin")
    }

    t.test("内置 agent 静态清单：非空、builtin=true、无文件路径") {
        let builtins = AgentDefinitionIndexer.builtinClaudeAgents()
        try expect(!builtins.isEmpty)
        try expect(builtins.allSatisfy { $0.builtin && $0.path.isEmpty })
        _ = try requireAgent(builtins, named: "general-purpose")
    }
}

private func writeAgent(_ root: URL, name: String, body: String) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try body.write(
        to: root.appendingPathComponent(name + ".md"), atomically: true, encoding: .utf8)
}

private func requireAgent(_ agents: [AgentDefinition], named name: String) throws -> AgentDefinition {
    guard let agent = agents.first(where: { $0.name == name }) else {
        throw ExpectationError(description: "未找到 agent \(name)")
    }
    return agent
}
