import EurekaIngest
import Foundation

func agentRoleTests(_ t: TestRunner) {
    t.suite("AgentRole")

    t.test("已知内置名精确映射") {
        try expectEqual(AgentRole.classify(name: "general-purpose"), .general)
        try expectEqual(AgentRole.classify(name: "Explore"), .explore)
        try expectEqual(AgentRole.classify(name: "Plan"), .plan)
        try expectEqual(AgentRole.classify(name: "wayfinder"), .plan)
        try expectEqual(AgentRole.classify(name: "coder"), .implement)
    }

    t.test("关键词启发：review 优先于其它角色") {
        try expectEqual(AgentRole.classify(name: "code-reviewer"), .review)
        try expectEqual(AgentRole.classify(name: "codex-reviewer"), .review)
        try expectEqual(AgentRole.classify(name: "silent-failure-hunter"), .review)
    }

    t.test("关键词启发：实现 / 探索 / 文档 / 建模") {
        try expectEqual(AgentRole.classify(name: "test-runner"), .implement)
        try expectEqual(AgentRole.classify(name: "kimi-scout"), .explore)
        try expectEqual(AgentRole.classify(name: "doc-writer"), .doc)
        try expectEqual(AgentRole.classify(name: "domain-modeler"), .model)
    }

    t.test("未知名兜底通用；描述参与判定") {
        try expectEqual(AgentRole.classify(name: "acme-helper"), .general)
        try expectEqual(AgentRole.classify(name: "acme", description: "审查改动 diff，先暴露风险"), .review)
    }

    t.test("角色单字与显示名") {
        try expectEqual(AgentRole.review.glyph, "审")
        try expectEqual(AgentRole.explore.displayName, "探索")
    }

    t.test("模型名规整") {
        try expectEqual(normalizeModelName(nil), "继承")
        try expectEqual(normalizeModelName("inherit"), "继承")
        try expectEqual(normalizeModelName("claude-opus-4"), "Opus")
        try expectEqual(normalizeModelName("sonnet"), "Sonnet")
        try expectEqual(normalizeModelName("gpt-5-codex"), "GPT-5-Codex")
        try expectEqual(normalizeModelName("kimi-k2"), "K2")
    }
}
