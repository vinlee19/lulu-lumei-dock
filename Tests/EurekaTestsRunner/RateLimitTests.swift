import EurekaKit
import EurekaUsage
import Foundation

func rateLimitTests(_ t: TestRunner) {
    t.suite("CodexRateLimitProvider")

    t.test("从 rollout 尾部取最后一条 rate_limits") {
        let snapshot = CodexRateLimitProvider.lastRateLimits(
            in: try fixtureURL("codex-rollout-token-count-ratelimits.jsonl"))
        try expect(snapshot != nil)
        // 文件里有两条 token_count，应取最后一条（3.5%/38.5%）
        try expectEqual(snapshot?.primary?.usedPercent, 3.5)
        try expectEqual(snapshot?.secondary?.usedPercent, 38.5)
        try expectEqual(snapshot?.primary?.windowMinutes, 300)
        try expectEqual(snapshot?.planType, "plus")
        try expectEqual(
            snapshot?.primary?.resetsAt,
            Date(timeIntervalSince1970: 1_781_028_000))
    }

    t.test("无 token_count 的文件返回 nil") {
        let snapshot = CodexRateLimitProvider.lastRateLimits(
            in: try fixtureURL("claude-transcript-api-error.jsonl"))
        try expect(snapshot == nil)
    }

    t.suite("ClaudeOAuthUsageProvider 响应解析")

    t.test("标准形态：小数 utilization 转百分比 + ISO 重置时间") {
        let json = """
        {"five_hour":{"utilization":0.32,"resets_at":"2026-06-10T16:00:00Z"},
         "seven_day":{"utilization":0.81,"resets_at":"2026-06-15T00:00:00Z"},
         "subscription_type":"max"}
        """
        let snapshot = ClaudeOAuthUsageProvider.parseUsageResponse(Data(json.utf8))
        try expect(snapshot != nil)
        try expectEqual(snapshot?.primary?.usedPercent, 32)
        try expectEqual(snapshot?.secondary?.usedPercent, 81)
        try expectEqual(snapshot?.planType, "max")
        try expect(snapshot?.primary?.resetsAt != nil)
    }

    t.test("百分数形态不二次放大") {
        let json = """
        {"five_hour":{"utilization":45.5},"seven_day":{"utilization":12}}
        """
        let snapshot = ClaudeOAuthUsageProvider.parseUsageResponse(Data(json.utf8))
        try expectEqual(snapshot?.primary?.usedPercent, 45.5)
        try expectEqual(snapshot?.secondary?.usedPercent, 12)
    }

    t.test("无法识别的响应返回 nil（→ UI 隐藏）") {
        try expect(ClaudeOAuthUsageProvider.parseUsageResponse(
            Data("{\"something\": 1}".utf8)) == nil)
        try expect(ClaudeOAuthUsageProvider.parseUsageResponse(
            Data("not json".utf8)) == nil)
    }
}
