import EurekaIngest
import EurekaKit
import Foundation

// 上下文用量估算：TokenEstimator 启发式、reconcile 对账数学、AgentContextProfile 配置表。

func contextBreakdownTests(_ t: TestRunner) {
    t.suite("ContextBreakdown")

    // MARK: - TokenEstimator

    t.test("纯英文：约 4 字符 1 token") {
        let estimate = TokenEstimator.estimate(String(repeating: "a", count: 400))
        try expectEqual(estimate, 100)
    }

    t.test("纯中文：每字符 1 token") {
        let estimate = TokenEstimator.estimate(String(repeating: "汉", count: 50))
        try expectEqual(estimate, 50)
    }

    t.test("混合文本介于两种口径之间且可预期") {
        // 100 个 ASCII + 20 个 CJK = 25 + 20
        let mixed = String(repeating: "a", count: 100) + String(repeating: "汉", count: 20)
        try expectEqual(TokenEstimator.estimate(mixed), 45)
    }

    t.test("单调性：追加文本估算不减少；空串为 0") {
        try expectEqual(TokenEstimator.estimate(""), 0)
        let base = TokenEstimator.estimate("hello 世界")
        let extended = TokenEstimator.estimate("hello 世界，再加一段文字")
        try expect(extended > base)
    }

    // MARK: - reconcile

    t.test("E < R：差值并入 systemPrompt，总量取真实值") {
        let breakdown = ContextBreakdownEstimator.reconcile(
            estimates: [.systemPrompt: 100, .tools: 50, .messages: 200, .mcp: 30, .skills: 20],
            windowTokens: 200_000,
            lastTurnTotalTokens: 1_000)
        try expectEqual(breakdown.tokens(for: .systemPrompt), 700)  // 100 + (1000-400)
        try expectEqual(breakdown.tokens(for: .messages), 200)
        try expectEqual(breakdown.totalTokens, 1_000)
        try expect(breakdown.totalIsReal)
    }

    t.test("E > R：各类等比缩放且合计严格等于 R") {
        let breakdown = ContextBreakdownEstimator.reconcile(
            estimates: [.systemPrompt: 333, .tools: 333, .messages: 334, .mcp: 0, .skills: 0],
            windowTokens: 200_000,
            lastTurnTotalTokens: 500)
        let sum = breakdown.entries.reduce(0) { $0 + $1.tokens }
        try expectEqual(sum, 500, "缩放后合计必须等于 R（舍入残差补最大类）")
        try expectEqual(breakdown.totalTokens, 500)
        try expect(breakdown.totalIsReal)
        // 等比：原本均分的三类缩放后仍近似相等
        try expect(abs(breakdown.tokens(for: .systemPrompt)
            - breakdown.tokens(for: .tools)) <= 1)
    }

    t.test("E == R：原样保留") {
        let breakdown = ContextBreakdownEstimator.reconcile(
            estimates: [.systemPrompt: 100, .messages: 100],
            windowTokens: 200_000,
            lastTurnTotalTokens: 200)
        try expectEqual(breakdown.tokens(for: .systemPrompt), 100)
        try expectEqual(breakdown.tokens(for: .messages), 100)
        try expectEqual(breakdown.totalTokens, 200)
        try expect(breakdown.totalIsReal)
    }

    t.test("无真实总量：totalIsReal == false，总量 = 估算合计") {
        let breakdown = ContextBreakdownEstimator.reconcile(
            estimates: [.systemPrompt: 100, .messages: 300],
            windowTokens: 200_000,
            lastTurnTotalTokens: nil)
        try expect(!breakdown.totalIsReal)
        try expectEqual(breakdown.totalTokens, 400)
    }

    t.test("真实总量为 0/负：按无真实值处理") {
        let breakdown = ContextBreakdownEstimator.reconcile(
            estimates: [.messages: 50],
            windowTokens: 200_000,
            lastTurnTotalTokens: 0)
        try expect(!breakdown.totalIsReal)
        try expectEqual(breakdown.totalTokens, 50)
    }

    // MARK: - AgentContextProfile

    t.test("已知源（claude/kimi/codex）配置目录表非空") {
        let home = URL(fileURLWithPath: "/tmp/fake-home")
        let cwd = "/tmp/fake-project"
        for source in [AgentSource.claude, .kimi, .codex] {
            let profile = AgentContextProfile.profile(for: source, cwd: cwd, home: home)
            try expect(!profile.skillDirs.isEmpty, "\(source) 应有技能目录")
            try expect(!profile.mcpConfigFiles.isEmpty, "\(source) 应有 MCP 配置")
            try expect(!profile.memoryFiles.isEmpty, "\(source) 应有记忆文件")
            try expect(profile.baselineSystemPromptTokens > 0)
            try expect(profile.baselineBuiltinToolTokens > 0)
            try expect(profile.perMCPServerTokens > 0)
        }
    }

    t.test("claude 配置路径含 home 级与 cwd 级") {
        let home = URL(fileURLWithPath: "/tmp/fake-home")
        let profile = AgentContextProfile.profile(
            for: .claude, cwd: "/tmp/fake-project", home: home)
        try expect(profile.skillDirs.contains("/tmp/fake-home/.claude/skills"))
        try expect(profile.skillDirs.contains("/tmp/fake-project/.claude/skills"))
        try expect(profile.memoryFiles.contains("/tmp/fake-project/CLAUDE.md"))
        try expect(profile.mcpConfigFiles.contains("/tmp/fake-project/.mcp.json"))
    }

    t.test("未知源安全回退：目录全空、基线仍在") {
        let profile = AgentContextProfile.profile(
            for: .grok, cwd: "/tmp/fake-project",
            home: URL(fileURLWithPath: "/tmp/fake-home"))
        try expect(profile.skillDirs.isEmpty)
        try expect(profile.mcpConfigFiles.isEmpty)
        try expect(profile.baselineSystemPromptTokens > 0)
    }

    t.test("cwd 为 nil 时不产出 cwd 级路径") {
        let profile = AgentContextProfile.profile(
            for: .claude, cwd: nil, home: URL(fileURLWithPath: "/tmp/fake-home"))
        try expect(profile.skillDirs.allSatisfy { $0.hasPrefix("/tmp/fake-home") })
        try expect(!profile.skillDirs.isEmpty)
    }

    // MARK: - LastTurnUsageReader 行格式（Claude 口径，经 reconcile 链路的真实值来源）

    t.test("estimate 端到端：真实总量压缩过高估算") {
        // 不依赖磁盘配置：未知源 + 空 home → 只有基线 + 消息文本
        let messages = [
            TranscriptMessage(id: 0, role: .user, text: String(repeating: "a", count: 400)),
        ]
        let breakdown = ContextBreakdownEstimator.estimate(
            source: .grok, cwd: nil, messages: messages, model: nil,
            lastTurnTotalTokens: 1_000,
            home: URL(fileURLWithPath: "/tmp/nonexistent-home"))
        try expect(breakdown.totalIsReal)
        try expectEqual(breakdown.totalTokens, 1_000)
        try expectEqual(breakdown.windowTokens, ContextWindows.defaultWindow)
        let sum = breakdown.entries.reduce(0) { $0 + $1.tokens }
        try expectEqual(sum, 1_000)
    }
}
