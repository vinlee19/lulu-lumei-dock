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

    t.suite("GrokRateLimitProvider 账单解析")

    t.test("billing 行 → 周窗 usedPercent + 计划 + 重置时间；单窗 secondary=nil") {
        let line = #"{"ts":"2026-07-16T03:37:05.302Z","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":42.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-09T09:49:33Z","end":"2026-07-16T09:49:33Z"}},"subscriptionTier":"SuperGrok"}}"#
        let snapshot = GrokRateLimitProvider.parse(Data(line.utf8))
        try expect(snapshot != nil)
        try expectEqual(snapshot?.source, .grok)
        try expectEqual(snapshot?.primary?.usedPercent, 42)
        try expectEqual(snapshot?.primary?.windowMinutes, 10080)
        try expectEqual(snapshot?.planType, "SuperGrok")
        try expect(snapshot?.secondary == nil, "Grok 单一配额池，无 secondary")
        try expect(snapshot?.primary?.resetsAt != nil, "重置时间不带小数秒也应解析")
    }

    t.test("creditUsagePercent 缺省（proto3 省零值，0% 周）→ 0") {
        let line = #"{"ts":"2026-07-16T03:37:05.302Z","msg":"billing: fetched credits config","ctx":{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-07-16T09:49:33Z"}}}}"#
        try expectEqual(GrokRateLimitProvider.parse(Data(line.utf8))?.primary?.usedPercent, 0)
    }

    t.test("非 billing 行 / 非 JSON → nil") {
        try expect(GrokRateLimitProvider.parse(Data(#"{"msg":"other"}"#.utf8)) == nil)
        try expect(GrokRateLimitProvider.parse(Data("not json".utf8)) == nil)
    }
}
