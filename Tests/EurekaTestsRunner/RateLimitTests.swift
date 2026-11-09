import EurekaKit
import EurekaUsage
import Foundation

func rateLimitTests(_ t: TestRunner) {
    t.suite("CodexRateLimitProvider")

    t.test("从 rollout 尾部取最后一条 rate_limits") {
        let snapshot = CodexRateLimitProvider.lastRateLimits(
            in: try fixtureURL("codex-rollout-token-count-ratelimits.jsonl"))
        try expect(snapshot != nil)
        // The file has two token_count entries; the last one (3.5%/38.5%) should win
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

    t.test("resume 的旧会话（老日期目录 + 新 mtime）能被发现为最新 rollout") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("eureka-cxrl-\(UUID().uuidString)", isDirectory: true)

        // Distractor file in today's directory: slightly older mtime
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let todayDir = root
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
        try fm.createDirectory(at: todayDir, withIntermediateDirectories: true)
        let decoy = todayDir.appendingPathComponent(
            "rollout-2026-07-26T10-00-00-decoy.jsonl")
        try fm.copyItem(
            at: fixtureURL("codex-rollout-token-count-ratelimits.jsonl"), to: decoy)
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: decoy.path)

        // A resumed old session: its creation-date directory is old, but in-place appends make its
        // mtime newest → it must beat the distractor
        let oldDayDir = root.appendingPathComponent("2025/01/01", isDirectory: true)
        try fm.createDirectory(at: oldDayDir, withIntermediateDirectories: true)
        let resumed = oldDayDir.appendingPathComponent(
            "rollout-2025-01-01T10-00-00-resumed.jsonl")
        try fm.copyItem(
            at: fixtureURL("codex-rollout-token-count-ratelimits.jsonl"), to: resumed)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: resumed.path)

        let provider = CodexRateLimitProvider(sessionsRoot: root)
        let found = provider.newestRollout()
        try expect(
            found?.lastPathComponent == resumed.lastPathComponent,
            "应发现老目录里的 resume 文件: \(String(describing: found))")
    }

    t.test("credits 全零 → nil；有积分 → 余额按积分数（不是美元）") {
        func limits(_ credits: String) -> [String: Any] {
            let json = #"{"primary":{"used_percent":0.0,"window_minutes":300,"resets_at":1793952887},"plan_type":"plus","credits":"# + credits + "}"
            return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        }
        let now = Date()
        let empty = CodexRateLimitParsing.snapshot(
            limits: limits(#"{"has_credits":false,"unlimited":false,"balance":"0"}"#), asOf: now)
        try expect(empty.credits == nil)
        try expectEqual(empty.primary?.usedPercent, 0)
        try expectEqual(empty.primary?.resetsAt, Date(timeIntervalSince1970: 1_793_952_887))

        let funded = CodexRateLimitParsing.snapshot(
            limits: limits(#"{"has_credits":true,"unlimited":false,"balance":"120"}"#), asOf: now)
        try expectEqual(funded.credits?.balance, 120)
        try expectEqual(funded.credits?.currency, nil)
        try expectEqual(funded.credits?.isEnabled, true)

        let unlimited = CodexRateLimitParsing.snapshot(
            limits: limits(#"{"has_credits":false,"unlimited":true,"balance":null}"#), asOf: now)
        try expectEqual(unlimited.credits?.isUnlimited, true)
    }

    t.test("rollout 尾部读取与 CodexRateLimitParsing 结果一致（两条读取路径不分叉）") {
        let fromFile = CodexRateLimitProvider.lastRateLimits(
            in: try fixtureURL("codex-rollout-token-count-ratelimits.jsonl"))
        try expectEqual(fromFile?.planType, "plus")
        try expectEqual(fromFile?.secondary?.windowMinutes, 10080)
        try expect(fromFile?.scopedWindows.isEmpty == true)
    }

    t.suite("ClaudeOAuthUsageProvider 响应解析")

    t.test("utilization 是 0–100 百分比：1 就是 1%，不是 100%（回归）") {
        // Before the fix, values <= 1 were read as 0-1 fractions, so every 1% window showed 100%
        let json = """
        {"five_hour":{"utilization":1,"resets_at":"2026-06-10T16:00:00Z"},
         "seven_day":{"utilization":0,"resets_at":"2026-06-15T00:00:00Z"}}
        """
        let snapshot = ClaudeOAuthUsageProvider.parseUsageResponse(Data(json.utf8))
        try expectEqual(snapshot?.primary?.usedPercent, 1)
        try expectEqual(snapshot?.secondary?.usedPercent, 0)
        try expect(snapshot?.primary?.resetsAt != nil)
        let fractional = ClaudeOAuthUsageProvider.parseUsageResponse(Data("""
        {"five_hour":{"utilization":0.5},"seven_day":{"utilization":45.5}}
        """.utf8))
        try expectEqual(fractional?.primary?.usedPercent, 0.5, "0.5 是 0.5%，不放大")
        try expectEqual(fractional?.secondary?.usedPercent, 45.5)
    }

    t.test("真实响应形态：百分比、6 位微秒重置时间、Fable 分模型周窗、额外用量未开启") {
        let snapshot = ClaudeOAuthUsageProvider.parseUsageResponse(
            try fixtureData("claude-oauth-usage.json"))
        try expectEqual(snapshot?.primary?.usedPercent, 0)
        try expectEqual(snapshot?.secondary?.usedPercent, 1)
        try expectEqual(snapshot?.primary?.windowMinutes, 300)
        try expectEqual(
            snapshot?.secondary?.resetsAt?.timeIntervalSince1970.rounded(.down),
            ISO8601DateFormatter().date(from: "2026-11-14T22:59:59Z")?.timeIntervalSince1970,
            "+00:00 加 6 位微秒的重置时间应能解析")
        try expectEqual(snapshot?.planType, nil, "用量响应里没有套餐字段")

        try expectEqual(snapshot?.scopedWindows.count, 1)
        let fable = snapshot?.scopedWindows.first
        try expectEqual(fable?.scope, "Fable")
        try expectEqual(fable?.usedPercent, 0)
        try expectEqual(fable?.windowMinutes, 10080)
        try expectEqual(fable?.capShareOfParent, 50, "按 limit_index 关联 weekly_scoped_shares")
        try expect(fable?.resetsAt != nil)

        let credits = snapshot?.credits
        try expect(credits != nil, "credits_ever_enabled=true 时即使未开启也要显示原因")
        try expectEqual(credits?.isEnabled, false)
        try expectEqual(credits?.disabledReason, "out_of_credits")
        try expectEqual(credits?.currency, "USD")
        try expectEqual(credits?.used, nil)
    }

    t.test("分模型周窗：limits[] 优先，旧 seven_day_* 键按名字去重补齐") {
        let json = """
        {"five_hour":{"utilization":3},"seven_day":{"utilization":20},
         "seven_day_opus":{"utilization":12,"resets_at":"2026-06-15T00:00:00Z"},
         "seven_day_sonnet":{"utilization":99},
         "limits":[{"kind":"weekly_scoped","percent":7,"resets_at":null,
                    "scope":{"model":{"display_name":"Sonnet"}}},
                   {"kind":"weekly_all","percent":20,"scope":null},
                   {"kind":"weekly_scoped","percent":5,"scope":null}]}
        """
        let windows = ClaudeOAuthUsageProvider.parseUsageResponse(Data(json.utf8))?.scopedWindows ?? []
        try expectEqual(windows.map(\.scope), ["Sonnet", "Opus"])
        try expectEqual(windows.map(\.usedPercent), [7, 12], "Sonnet 取 limits[] 的 7 而不是旧键的 99")
        try expectEqual(windows.first?.capShareOfParent, nil, "没有 shares 就不编造上限")
    }

    t.test("额外用量开启：最小货币单位换算成美元") {
        let json = """
        {"five_hour":{"utilization":3},
         "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1230,
                        "currency":"usd","decimal_places":2,"disabled_reason":null}}
        """
        let credits = ClaudeOAuthUsageProvider.parseUsageResponse(Data(json.utf8))?.credits
        try expectEqual(credits?.isEnabled, true)
        try expectEqual(credits?.used, 12.3)
        try expectEqual(credits?.limit, 50)
        try expectEqual(credits?.currency, "USD")
        try expectEqual(credits?.disabledReason, nil)
    }

    t.test("额外用量从未开启且未花钱 → nil（不显示）") {
        let json = """
        {"five_hour":{"utilization":3},
         "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,
                        "credits_ever_enabled":false,"disabled_reason":"not_enabled"}}
        """
        try expect(ClaudeOAuthUsageProvider.parseUsageResponse(Data(json.utf8))?.credits == nil)
    }

    t.test("套餐徽章：订阅类型 + Max 档位") {
        typealias P = ClaudeOAuthUsageProvider
        try expectEqual(P.planLabel(subscriptionType: "team", rateLimitTier: "default_claude_max_5x"), "Team · Max 5x")
        try expectEqual(P.planLabel(subscriptionType: "max", rateLimitTier: "default_claude_max_20x"), "Max 20x")
        try expectEqual(P.planLabel(subscriptionType: "pro", rateLimitTier: "default_claude_ai"), "Pro")
        try expectEqual(P.planLabel(subscriptionType: "enterprise", rateLimitTier: nil), "Enterprise")
        try expectEqual(P.planLabel(subscriptionType: nil, rateLimitTier: "default_claude_max_5x"), "Max 5x")
        try expectEqual(P.planLabel(subscriptionType: "custom_plan", rateLimitTier: nil), "Custom_plan")
        try expectEqual(P.planLabel(subscriptionType: nil, rateLimitTier: nil), nil)
        try expectEqual(P.planLabel(subscriptionType: " ", rateLimitTier: "unknown_tier"), nil)
    }

    t.test("凭证解析：claudeAiOauth 包裹与平铺两种形态，缺 token → nil") {
        // Fake values only; the real Keychain is never read by tests
        let wrapped = #"{"claudeAiOauth":{"accessToken":"fake-token","subscriptionType":"team","rateLimitTier":"default_claude_max_5x"}}"#
        let parsed = ClaudeOAuthUsageProvider.parseCredentials(wrapped + "\n")
        try expectEqual(parsed?.accessToken, "fake-token")
        try expectEqual(parsed?.subscriptionType, "team")
        try expectEqual(parsed?.rateLimitTier, "default_claude_max_5x")

        let flat = ClaudeOAuthUsageProvider.parseCredentials(#"{"accessToken":"fake-flat"}"#)
        try expectEqual(flat?.accessToken, "fake-flat")
        try expectEqual(flat?.subscriptionType, nil)

        try expect(ClaudeOAuthUsageProvider.parseCredentials(#"{"claudeAiOauth":{"subscriptionType":"pro"}}"#) == nil)
        try expect(ClaudeOAuthUsageProvider.parseCredentials("not json") == nil)
    }

    t.test("无法识别的响应返回 nil（→ UI 隐藏）") {
        try expect(ClaudeOAuthUsageProvider.parseUsageResponse(
            Data("{\"something\": 1}".utf8)) == nil)
        try expect(ClaudeOAuthUsageProvider.parseUsageResponse(
            Data("not json".utf8)) == nil)
    }

    t.suite("ClaudeOAuthUsageProvider 限流退避（假服务器，不访问网络）")

    t.test("429 带 Retry-After：等待期内（包括刷新按钮）一个请求都不发，到点才再请求") {
        let clock = FakeClock()
        let server = FakeUsageServer([(200, [:]), (429, ["Retry-After": "600"]), (200, [:])])
        let provider = makeClaudeProvider(server, clock)
        let first = runAwaiting { await provider.snapshot() }
        try expectEqual(first?.primary?.usedPercent, 7)
        try expectEqual(server.requests, 1)

        clock.advance(61)
        let limited = runAwaiting { await provider.snapshot() }
        try expectEqual(server.requests, 2)
        try expectEqual(limited?.isStale, true, "429 时显示上次数值并标为过期")
        try expectEqual(limited?.primary?.usedPercent, 7)
        try expect(provider.lastFailure?.contains("429") == true)

        clock.advance(300)
        _ = runAwaiting { await provider.snapshot() }
        try expectEqual(server.requests, 2, "退避期内不请求")

        clock.advance(300)
        let recovered = runAwaiting { await provider.snapshot() }
        try expectEqual(server.requests, 3)
        try expectEqual(recovered?.isStale, false)
        try expectEqual(provider.lastFailure, nil)
    }

    t.test("没有 Retry-After：连续 429 按 5→10→20→40→60 分钟退避，成功后清零") {
        typealias P = ClaudeOAuthUsageProvider
        try expectEqual([1, 2, 3, 4, 5, 9].map { P.backoff(afterRateLimits: $0) },
                        [300, 600, 1200, 2400, 3600, 3600])
        let clock = FakeClock()
        let server = FakeUsageServer([(429, [:]), (429, [:]), (200, [:])])
        let provider = makeClaudeProvider(server, clock)
        _ = runAwaiting { await provider.snapshot() }
        try expectEqual(provider.persistedState.consecutiveRateLimits, 1)
        // A 5-minute timer tick that fires a little early still counts as the end of the wait
        clock.advance(295)
        _ = runAwaiting { await provider.snapshot() }
        try expectEqual(server.requests, 2)
        try expectEqual(provider.persistedState.consecutiveRateLimits, 2)
        clock.advance(300)
        _ = runAwaiting { await provider.snapshot() }
        try expectEqual(server.requests, 2, "第二次 429 后要等 10 分钟")
        clock.advance(300)
        _ = runAwaiting { await provider.snapshot() }
        try expectEqual(server.requests, 3)
        try expectEqual(provider.persistedState.consecutiveRateLimits, 0)
        try expectEqual(provider.persistedState.nextAllowedAt, nil)
    }

    t.test("Retry-After: 0（服务器实际这么回）不能把退避缩短到 60 秒") {
        let clock = FakeClock()
        let server = FakeUsageServer([(429, ["Retry-After": "0"]), (200, [:])])
        let provider = makeClaudeProvider(server, clock)
        _ = runAwaiting { await provider.snapshot() }
        clock.advance(120)
        _ = runAwaiting { await provider.snapshot() }
        try expectEqual(server.requests, 1, "仍按 5 分钟退避")
        clock.advance(180)
        _ = runAwaiting { await provider.snapshot() }
        try expectEqual(server.requests, 2)
    }

    t.test("旧版本存下的短等待，重启后按当前退避表重新计算") {
        let clock = FakeClock()
        let saved = ClaudeOAuthUsageProvider.PersistedState(
            lastSnapshot: nil, lastAttemptAt: clock.now,
            nextAllowedAt: clock.now.addingTimeInterval(60), consecutiveRateLimits: 2)
        clock.advance(120)
        let server = FakeUsageServer([(200, [:])])
        let provider = makeClaudeProvider(server, clock)
        provider.restore(saved)
        _ = runAwaiting { await provider.snapshot() }
        try expectEqual(server.requests, 0, "第 2 次 429 要等 10 分钟，不是旧值的 60 秒")
        clock.advance(480)
        _ = runAwaiting { await provider.snapshot() }
        try expectEqual(server.requests, 1)
    }

    t.test("重启时上次成功不到 5 分钟：直接沿用，不马上请求；到点再按节奏请求") {
        let clock = FakeClock()
        let first = makeClaudeProvider(FakeUsageServer([(200, [:])]), clock)
        _ = runAwaiting { await first.snapshot() }
        let state = first.persistedState

        clock.advance(69)
        let server = FakeUsageServer([(200, [:])])
        let relaunched = makeClaudeProvider(server, clock)
        relaunched.restore(state)
        let shown = runAwaiting { await relaunched.snapshot() }
        try expectEqual(server.requests, 0)
        try expectEqual(shown?.isStale, false, "1 分钟前的数值不算过期")
        try expectEqual(shown?.primary?.usedPercent, 7)
        clock.advance(231)
        _ = runAwaiting { await relaunched.snapshot() }
        try expectEqual(server.requests, 1, "满 5 分钟后照常请求")
    }

    t.test("60 秒内重复刷新只发一次请求，返回的仍是新鲜数值") {
        let clock = FakeClock()
        let server = FakeUsageServer([(200, [:]), (200, [:])])
        let provider = makeClaudeProvider(server, clock)
        _ = runAwaiting { await provider.snapshot() }
        clock.advance(30)
        let again = runAwaiting { await provider.snapshot() }
        try expectEqual(server.requests, 1)
        try expectEqual(again?.isStale, false)
    }

    t.test("重启后：先显示上次数值（过期），退避期内不请求") {
        let clock = FakeClock()
        let first = makeClaudeProvider(FakeUsageServer([(200, [:]), (429, ["Retry-After": "900"])]), clock)
        _ = runAwaiting { await first.snapshot() }
        clock.advance(61)
        _ = runAwaiting { await first.snapshot() }
        let saved = try JSONEncoder().encode(first.persistedState)
        let state = try JSONDecoder().decode(ClaudeOAuthUsageProvider.PersistedState.self, from: saved)

        clock.advance(60)
        let server = FakeUsageServer([(200, [:])])
        let relaunched = makeClaudeProvider(server, clock)
        let shown = relaunched.restore(state)
        try expectEqual(shown?.primary?.usedPercent, 7)
        try expectEqual(shown?.isStale, true)
        try expect(relaunched.lastFailure?.contains("429") == true)
        _ = runAwaiting { await relaunched.snapshot() }
        try expectEqual(server.requests, 0, "重启不能跳过退避")
    }

    t.test("Retry-After：秒数与 HTTP 日期两种写法，无法识别 → nil") {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try expectEqual(ClaudeOAuthUsageProvider.retryAfter("120", now: now), 120)
        let date = ClaudeOAuthUsageProvider.retryAfter("Fri, 15 Jan 2027 08:00:30 GMT", now: Date(timeIntervalSince1970: 1_800_000_000))
        try expectEqual(date, 30)
        try expectEqual(ClaudeOAuthUsageProvider.retryAfter("soon", now: now), nil)
        try expectEqual(ClaudeOAuthUsageProvider.retryAfter(nil, now: now), nil)
    }

    t.suite("ClaudeOAuthUsageProvider 读 Claude Code 自己的缓存（~/.claude.json）")

    t.test("解析 cachedUsageUtilization：数值、时间取 fetchedAt、套餐来自 oauthAccount") {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ClaudeOAuthUsageProvider.parseClaudeCodeCache(
            try fakeClaudeCodeConfig(fetchedAt: fetchedAt))
        try expectEqual(snapshot?.asOf, fetchedAt)
        try expectEqual(snapshot?.secondary?.usedPercent, 1)
        try expectEqual(snapshot?.planType, "Team · Max 5x")
        try expectEqual(snapshot?.scopedWindows.first?.scope, "Fable")
        try expectEqual(snapshot?.credits?.disabledReason, "out_of_credits")
    }

    t.test("缓存属于别的账号 / 没有缓存 / 不是 JSON → 不用") {
        let other = try fakeClaudeCodeConfig(fetchedAt: Date(), cacheAccount: "acct-old")
        try expect(ClaudeOAuthUsageProvider.parseClaudeCodeCache(other) == nil)
        try expect(ClaudeOAuthUsageProvider.parseClaudeCodeCache(Data(#"{"oauthAccount":{}}"#.utf8)) == nil)
        try expect(ClaudeOAuthUsageProvider.parseClaudeCodeCache(Data("{".utf8)) == nil)
    }

    t.test("缓存 10 分钟内：直接用，一个请求都不发；退避期间也一样，且不再显示 429 提示") {
        let clock = FakeClock()
        let server = FakeUsageServer([(429, ["Retry-After": "0"])])
        let noCache = makeClaudeProvider(server, clock)
        _ = runAwaiting { await noCache.snapshot() }
        try expectEqual(server.requests, 1)
        let state = noCache.persistedState

        let config = try fakeClaudeCodeConfig(fetchedAt: clock.now.addingTimeInterval(-180))
        let withCache = makeClaudeProvider(server, clock, claudeCodeConfig: config)
        withCache.restore(state)
        clock.advance(30)
        let shown = runAwaiting { await withCache.snapshot() }
        try expectEqual(server.requests, 1, "有新鲜缓存就不请求")
        try expectEqual(shown?.isStale, false)
        try expectEqual(shown?.secondary?.usedPercent, 1)
        try expectEqual(shown?.planType, "Team · Max 5x")
        try expectEqual(withCache.lastFailure, nil)
    }

    t.test("缓存超过 10 分钟：照常走接口；接口的新结果比旧缓存优先") {
        let clock = FakeClock()
        let server = FakeUsageServer([(200, [:])])
        let config = try fakeClaudeCodeConfig(fetchedAt: clock.now.addingTimeInterval(-900))
        let provider = makeClaudeProvider(server, clock, claudeCodeConfig: config)
        let shown = runAwaiting { await provider.snapshot() }
        try expectEqual(server.requests, 1)
        try expectEqual(shown?.primary?.usedPercent, 7, "用接口的新数值，不是缓存的 0")
        try expectEqual(shown?.isStale, false)
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

    t.test("按量付费：Cent {val} 换算成美元；proto3 缺省为 0；全零且未开启 → nil") {
        let funded = #"{"ts":"2026-11-09T05:31:46.595Z","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":75.0,"onDemandCap":{"val":2000},"onDemandUsed":{"val":320},"prepaidBalance":{"val":500}},"onDemandEnabled":true,"subscriptionTier":"SuperGrok"}}"#
        let credits = GrokRateLimitProvider.parse(Data(funded.utf8))?.credits
        try expectEqual(credits?.used, 3.2)
        try expectEqual(credits?.limit, 20)
        try expectEqual(credits?.balance, 5)
        try expectEqual(credits?.currency, "USD")

        let zero = #"{"ts":"2026-11-09T05:31:46.595Z","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":75.0,"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0}},"onDemandEnabled":false,"subscriptionTier":"SuperGrok"}}"#
        try expect(GrokRateLimitProvider.parse(Data(zero.utf8))?.credits == nil)

        let enabledEmpty = #"{"ts":"2026-11-09T05:31:46.595Z","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":10.0},"onDemandEnabled":true}}"#
        let enabled = GrokRateLimitProvider.parse(Data(enabledEmpty.utf8))?.credits
        try expectEqual(enabled?.isEnabled, true, "开启了按量付费，金额为 0 也要显示")
        try expectEqual(enabled?.used, 0)
        try expectEqual(enabled?.limit, nil)
    }

    t.test("非 billing 行 / 非 JSON → nil") {
        try expect(GrokRateLimitProvider.parse(Data(#"{"msg":"other"}"#.utf8)) == nil)
        try expect(GrokRateLimitProvider.parse(Data("not json".utf8)) == nil)
    }

    t.suite("AntigravityQuotaProvider（agy /usage）解析")

    t.test("各组各窗口 → scoped 窗口：已用 = (1 - remaining_fraction) × 100，组名作 scope") {
        let snapshot = AntigravityQuotaProvider.parseUsage(try fixtureData("agy-usage.json"))
        try expectEqual(snapshot?.source, .antigravity)
        try expect(snapshot?.primary == nil && snapshot?.secondary == nil, "全部是 scoped，不进菜单栏和预测")
        let windows = snapshot?.scopedWindows ?? []
        try expectEqual(windows.count, 6)
        try expectEqual(windows.map(\.scope), [
            "Gemini Models", "Gemini Models", "Claude and GPT models", "Claude and GPT models",
            "Gemini 4 Argon", "Gemini 4 Argon",
        ])
        try expectEqual(windows.map(\.windowMinutes), [10080, 300, 10080, 300, 10080, 0])
        try expectEqual(windows[0].usedPercent.rounded(), 27)
        try expectEqual(windows[1].usedPercent, 50)
        try expectEqual(windows[3].usedPercent, 100, "remaining 0 → 用满")
        try expect(windows[3].resetsAt != nil, "带毫秒的重置时间也能解析")
        try expectEqual(windows[5].label, "Argon Burst Limit", "未知窗口沿用桶名")
        try expectEqual(windows[5].resetsAt, nil)
        try expectEqual(windows[0].label, nil, "已知窗口不存标签，界面按语言渲染")
    }

    t.test("前置噪声可容忍；失败状态 / 无 groups / 非 JSON → nil") {
        let noisy = Data("warning: something\n".utf8) + (try fixtureData("agy-usage.json"))
        try expectEqual(AntigravityQuotaProvider.parseUsage(noisy)?.scopedWindows.count, 6)
        try expect(AntigravityQuotaProvider.parseUsage(Data(#"{"status":"ERROR","command":{"name":"usage","data":{"groups":[]}}}"#.utf8)) == nil)
        try expect(AntigravityQuotaProvider.parseUsage(Data(#"{"status":"SUCCESS","response":"hi"}"#.utf8)) == nil)
        try expect(AntigravityQuotaProvider.parseUsage(Data("not json".utf8)) == nil)
    }

    t.suite("OpencodeGoProvider（opencode api experimental.usage.limits）解析")

    t.test("go 三个计量 → 滚动 / 周 / 月窗口，resetsAt 为毫秒；limited 视为用满") {
        let json = #"{"location":{"directory":"/tmp"},"data":{"workspace":{"id":"wrk_1","name":null,"usageURL":"https://opencode.ai"},"go":{"rolling":{"percent":12.5,"limited":false,"resetsAt":1794200000000},"weekly":{"percent":40,"limited":false,"resetsAt":1794700000000},"monthly":{"percent":80,"limited":true,"resetsAt":1796000000000}},"budgets":[]}}"#
        let snapshot = OpencodeGoProvider.parseLimits(Data(json.utf8))
        try expectEqual(snapshot?.source, .opencode)
        try expectEqual(snapshot?.planType, "Go")
        let windows = snapshot?.scopedWindows ?? []
        try expectEqual(windows.map(\.windowMinutes), [0, 10080, 43200])
        try expectEqual(windows.map(\.usedPercent), [12.5, 40, 100])
        try expectEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1_794_200_000))
        try expectEqual(windows[0].label, nil, "滚动窗口的名字由界面按语言给出")
    }

    t.test("新增的计量不会被丢掉：未知键按键名作标签，排在已知计量之后") {
        let json = #"{"data":{"go":{"weekly":{"percent":10,"limited":false,"resetsAt":1794700000000},"burst":{"percent":55,"limited":false,"resetsAt":1794100000000},"rolling":{"percent":5,"limited":false,"resetsAt":1794200000000},"note":"not a meter"}}}"#
        let windows = OpencodeGoProvider.parseLimits(Data(json.utf8))?.scopedWindows ?? []
        try expectEqual(windows.map(\.usedPercent), [5, 10, 55])
        try expectEqual(windows.map(\.label), [nil, nil, "burst"])
    }

    t.test("未登录（data null）→ signedOut；无 Go 订阅（有 workspace 无 go）→ noPlan；都不显示窗口") {
        let signedOut = OpencodeGoProvider.parseLimits(Data(#"{"location":{"directory":"/Users/x"},"data":null}"#.utf8))
        try expectEqual(signedOut?.planStatus, .signedOut)
        try expect(signedOut?.scopedWindows.isEmpty == true)
        try expectEqual(signedOut?.planType, nil)
        let noPlan = OpencodeGoProvider.parseLimits(Data(#"{"location":{},"data":{"workspace":{"id":"w","usageURL":"u"},"budgets":[]}}"#.utf8))
        try expectEqual(noPlan?.planStatus, .noPlan)
        try expect(noPlan?.scopedWindows.isEmpty == true)
    }

    t.test("认不出的回答仍然隐藏：非 JSON / data 不是对象也不是 null / 没有 workspace 也没有 go") {
        try expect(OpencodeGoProvider.parseLimits(Data("oops".utf8)) == nil)
        try expect(OpencodeGoProvider.parseLimits(Data(#"{"data":"weird"}"#.utf8)) == nil)
        try expect(OpencodeGoProvider.parseLimits(Data(#"{"data":{"budgets":[]}}"#.utf8)) == nil)
        try expectEqual(OpencodeGoProvider.parseLimits(Data(#"{"data":{"go":{"weekly":{"percent":10}}}}"#.utf8))?.planStatus, nil)
    }

    t.suite("RateLimitCreditsText 文案")

    t.test("各来源的额度说明（英文源语言）") {
        let saved = L10n.current
        L10n.current = .english
        defer { L10n.current = saved }
        typealias T = RateLimitCreditsText
        try expectEqual(T.line(for: RateLimitCredits(isEnabled: true, used: 12.3, limit: 50, currency: "USD"), source: .claude).text, "Extra usage $12.30 / $50.00 this month")
        let off = T.line(for: RateLimitCredits(isEnabled: false, currency: "USD", disabledReason: "out_of_credits"), source: .claude)
        try expectEqual(off.text, "Extra usage off · out of credits")
        try expectEqual(off.help, "out_of_credits")
        try expectEqual(T.line(for: RateLimitCredits(isEnabled: false, currency: "USD", disabledReason: "org_disabled"), source: .claude).text, "Extra usage off")
        try expectEqual(T.line(for: RateLimitCredits(isEnabled: true, balance: 120), source: .codex).text, "Credits balance 120")
        try expectEqual(T.line(for: RateLimitCredits(isEnabled: true, isUnlimited: true), source: .codex).text, "Credits: unlimited")
        try expectEqual(T.line(for: RateLimitCredits(isEnabled: true, used: 3.2, limit: 20, balance: 5, currency: "USD"), source: .grok).text, "Pay-as-you-go $3.20 / $20.00 · Prepaid balance $5.00")
        try expectEqual(T.line(for: RateLimitCredits(isEnabled: false, balance: 5, currency: "USD"), source: .grok).text, "Prepaid balance $5.00")
        try expectEqual(T.amount(12.5, currency: "EUR"), "12.50 EUR")
        try expectEqual(T.amount(7.25, currency: nil), "7.25")
        L10n.current = .simplifiedChinese
        try expectEqual(off.help, "out_of_credits")
        try expectEqual(T.line(for: RateLimitCredits(isEnabled: false, currency: "USD", disabledReason: "out_of_credits"), source: .claude).text, "额外用量未开启 · 余额用尽")
        try expectEqual(T.line(for: RateLimitCredits(isEnabled: true, used: 12.3, limit: 50, currency: "USD"), source: .claude).text, "额外用量 $12.30 / $50.00（本月）")
    }
}

// MARK: - Helpers for the provider backoff tests

/// Runs an async call from the synchronous harness (the provider is not main-actor bound)
private func runAwaiting<T>(_ body: @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached {
        box.value = await body()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value!
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

private final class FakeClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Stands in for api.anthropic.com: replies in order, counts requests
private final class FakeUsageServer: @unchecked Sendable {
    private var replies: [(status: Int, headers: [String: String])]
    private(set) var requests = 0

    init(_ replies: [(Int, [String: String])]) {
        self.replies = replies.map { (status: $0.0, headers: $0.1) }
    }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        let reply = replies.isEmpty ? (status: 200, headers: [:]) : replies.removeFirst()
        let body = reply.status == 200
            ? Data(#"{"five_hour":{"utilization":7},"seven_day":{"utilization":3}}"#.utf8) : Data()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: nil,
            headerFields: reply.headers)!
        return (body, response)
    }
}

private func makeClaudeProvider(
    _ server: FakeUsageServer, _ clock: FakeClock, claudeCodeConfig: Data? = nil
) -> ClaudeOAuthUsageProvider {
    ClaudeOAuthUsageProvider(
        fetch: { try await server.fetch($0) },
        credentials: {
            ClaudeOAuthUsageProvider.ClaudeCredentials(
                accessToken: "fake-token", subscriptionType: "team",
                rateLimitTier: "default_claude_max_5x")
        },
        // Never the real ~/.claude.json
        claudeCodeConfig: { claudeCodeConfig },
        clock: { clock.now })
}

/// A stand-in ~/.claude.json: Claude Code's cached usage answer plus the account fields read
/// next to it (fake ids, a placeholder address that must never matter)
private func fakeClaudeCodeConfig(
    fetchedAt: Date, cacheAccount: String = "acct-1", currentAccount: String = "acct-1"
) throws -> Data {
    let utilization = try JSONSerialization.jsonObject(with: try fixtureData("claude-oauth-usage.json"))
    let root: [String: Any] = [
        "oauthAccount": [
            "accountUuid": currentAccount, "organizationType": "claude_team",
            "userRateLimitTier": "default_claude_max_5x", "emailAddress": "someone@example.com",
        ],
        "projects": ["/tmp/x": ["allowedTools": []]],
        "cachedUsageUtilization": [
            "fetchedAtMs": fetchedAt.timeIntervalSince1970 * 1000,
            "accountUuid": cacheAccount, "utilization": utilization,
        ],
    ]
    return try JSONSerialization.data(withJSONObject: root)
}
