import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

/// 用样本（从真实 LiteLLM / models.dev 裁出的子集）构建目录；样本条目少，下限调低
private func sampleCatalog() throws -> PriceCatalog {
    let litellm = try PriceCatalogParser.parseLiteLLM(
        fixtureData("pricing/litellm-sample.json"), minEntries: 10)
    let modelsDev = try PriceCatalogParser.parseModelsDev(
        fixtureData("pricing/modelsdev-sample.json"), minProviders: 5)
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    return PriceCatalog(
        litellm: litellm, modelsDev: modelsDev,
        litellmMeta: .init(fetchedAt: now, entryCount: litellm.count),
        modelsDevMeta: .init(fetchedAt: now, entryCount: modelsDev.count))
}

/// 随包手写表的关键条目（软 unknown + 硬 unknown + 旧前缀）
private let bundledSample: [ModelPrice] = [
    ModelPrice(match: "gpt-5", inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125),
    ModelPrice(match: "claude-opus", inputPerM: 15, outputPerM: 75),
    ModelPrice(match: "kimi-code/", unknown: true),
    ModelPrice(match: "glm-", unknown: true),
    ModelPrice(match: "gemini", unknown: true),
    ModelPrice(match: "cursor/", unknown: true, authoritative: true),
]

private func makeTable(
    overrides: [ModelPrice] = [], aliases: [String: ProviderAlias] = [:]
) throws -> PricingTable {
    PricingTable(resolver: PriceResolver(
        overrides: overrides, bundled: bundledSample, aliases: aliases, catalog: try sampleCatalog()))
}

func pricingCatalogTests(_ t: TestRunner) {
    t.suite("PricingCatalog 解析与校验")

    t.test("LiteLLM：按 token 计价换算为每百万，含 1h 缓存写") {
        let catalog = try sampleCatalog()
        let opus = try expectSome(catalog.litellm["claude-opus-5"])
        try expectEqual(opus.inputPerM, 5)
        try expectEqual(opus.outputPerM, 25)
        try expectEqual(opus.cacheReadPerM, 0.5)
        try expectEqual(opus.cacheWrite5mPerM, 6.25)
        try expectEqual(opus.cacheWrite1hPerM, 10)
    }

    t.test("LiteLLM：跳过 sample_spec / 非对话 mode / 坏数值") {
        let catalog = try sampleCatalog()
        try expect(catalog.litellm["sample_spec"] == nil)
        try expect(catalog.litellm["decoy-negative"] == nil, "负价格应被丢弃")
        try expect(!catalog.litellm.values.contains { $0.inputPerM < 0 })
    }

    t.test("LiteLLM：转售平台的裸键改挂到 <平台>/ 下，不会被裸名当官方价") {
        let catalog = try sampleCatalog()
        try expect(catalog.litellm["together-ai-21.1b-41b"] == nil)
        try expect(catalog.litellm["together_ai/together-ai-21.1b-41b"] != nil)
    }

    t.test("models.dev：id 小写、识别订阅套餐、显式 0 缓存写保留为 0") {
        let catalog = try sampleCatalog()
        try expect(catalog.modelsDev["minimax"]?.models["minimax-m3"] != nil, "MiniMax-M3 应被小写化")
        try expectEqual(catalog.modelsDev["kimi-code-plan-cn"]?.subscription, true)
        try expectEqual(catalog.modelsDev["zhipuai-coding-plan"]?.subscription, true)
        try expectEqual(catalog.modelsDev["zhipuai"]?.subscription, false)
        try expectEqual(catalog.modelsDev["zhipuai"]?.models["glm-5.2"]?.cacheWrite5mPerM, 0)
    }

    t.test("校验：条目过少 / 骤减一半 / 超体积 均拒收") {
        let data = try fixtureData("pricing/litellm-sample.json")
        do {
            _ = try PriceCatalogParser.parseLiteLLM(data)  // 默认下限 1000
            throw ExpectationError(description: "样本仅几十条，应因条目过少被拒")
        } catch is CatalogValidationError {}
        do {
            try PriceCatalogParser.checkNotCollapsed(new: 400, previous: 1000, name: "LiteLLM")
            throw ExpectationError(description: "骤减到 40% 应被拒")
        } catch is CatalogValidationError {}
        try PriceCatalogParser.checkNotCollapsed(new: 900, previous: 1000, name: "LiteLLM")
        let huge = Data(count: PriceCatalogParser.litellmMaxBytes + 1)
        do {
            _ = try PriceCatalogParser.parseLiteLLM(huge, minEntries: 0)
            throw ExpectationError(description: "超体积应被拒")
        } catch is CatalogValidationError {}
    }

    t.suite("ModelNameNormalizer")

    t.test("拆 provider/model，cursor/ 不拆") {
        try expectEqual(ModelNameNormalizer.split("kimi-code/k3").provider, "kimi-code")
        try expectEqual(ModelNameNormalizer.split("kimi-code/k3").model, "k3")
        try expectEqual(ModelNameNormalizer.split("cursor/gpt-5.1").provider, nil)
        try expectEqual(ModelNameNormalizer.split("gpt-5.6-sol").provider, nil)
    }

    t.test("候选名：原名优先、去日期、去档位、版本点横互转、k3→kimi-k3") {
        let glm = ModelNameNormalizer.candidates("glm-5-2-260617")
        try expectEqual(glm.first, "glm-5-2-260617")
        try expect(glm.contains("glm-5.2"), "\(glm)")
        let haiku = ModelNameNormalizer.candidates("claude-haiku-4-5-20251001")
        try expect(haiku.contains("claude-haiku-4-5") && haiku.contains("claude-haiku-4.5"), "\(haiku)")
        let opus = ModelNameNormalizer.candidates("claude-4.5-opus-high-thinking")
        try expect(opus.contains("claude-4.5-opus"), "\(opus)")
        let kimi = ModelNameNormalizer.candidates("k3-256k")
        try expect(kimi.contains("k3") && kimi.contains("kimi-k3"), "\(kimi)")
    }

    t.suite("PriceResolver 查找顺序")

    t.test("新 GPT 模型走 LiteLLM，不再退回 gpt-5 家族价") {
        let table = try makeTable()
        let sol = table.resolution(for: "gpt-5.6-sol", provider: nil)
        try expectEqual(sol.price?.inputPerM, 4)
        try expectEqual(sol.source, .litellm)
        try expectEqual(table.price(for: "gpt-6-sol")?.inputPerM, 2)
        try expectEqual(table.price(for: "gpt-6-astra")?.outputPerM, 50)
    }

    t.test("Claude 新模型取目录价，不再套 claude-opus 前缀的 $15") {
        let table = try makeTable()
        try expectEqual(table.price(for: "claude-opus-5")?.inputPerM, 5)
        try expectEqual(table.price(for: "claude-opus-5-5")?.inputPerM, 4)
        try expectEqual(table.price(for: "claude-fable-5")?.inputPerM, 10)
    }

    t.test("用户覆盖优先于一切；覆盖里的 unknown 权威") {
        let table = try makeTable(overrides: [
            ModelPrice(match: "gpt-6-sol", inputPerM: 99, outputPerM: 99),
            ModelPrice(match: "gpt-5.6", unknown: true),
        ])
        try expectEqual(table.price(for: "gpt-6-sol")?.inputPerM, 99)
        try expect(table.price(for: "gpt-5.6-sol") == nil)
    }

    t.test("cursor/ 硬性不算钱，即使目录里有同名模型") {
        let table = try makeTable()
        try expect(table.price(for: "cursor/gpt-5.1") == nil)
    }

    t.test("glm- 软 unknown 让位于远程目录；目录也没有时才不算钱") {
        let table = try makeTable()
        let glm = table.resolution(for: "glm-5.3", provider: nil)
        try expectEqual(glm.price?.inputPerM, 1.4)
        try expectEqual(glm.source, .modelsDev("zhipuai"))
        try expect(table.price(for: "glm-9-imaginary") == nil)
    }

    t.test("订阅套餐按厂商按量价折算，并标订阅") {
        let table = try makeTable()
        let k3 = table.resolution(for: "kimi-code/k3", provider: nil)
        try expectEqual(k3.price?.inputPerM, 3)
        try expectEqual(k3.subscription, true)
        let plan = table.resolution(for: "glm-5.3", provider: "zhipuai-coding-plan")
        try expectEqual(plan.price?.inputPerM, 1.4)
        try expectEqual(plan.subscription, true)
        // 用户自定义名里带 plan 也视为订阅
        try expectEqual(table.resolution(for: "glm-5.2", provider: "coding-plan").subscription, true)
    }

    t.test("只有转售平台报价的模型不计价；用户明确走转售平台才采信") {
        let table = try makeTable()
        try expect(table.price(for: "hy3-free") == nil, "hy3-free 只在 orcarouter 有报价")
        try expect(table.price(for: "deepseek-v4.1-flash") == nil, "只在 openrouter 有报价")
        let explicit = table.resolution(for: "deepseek-v4.1-flash", provider: "openrouter")
        try expect(explicit.price != nil, "用户明确走 openrouter 时采信其报价")
    }

    t.test("托管方 provider 取托管方价；opencode 免费模型为 $0") {
        let table = try makeTable()
        try expectEqual(
            table.resolution(for: "glm-5-2-260617", provider: "volcengine").source, .modelsDev("volcengine"))
        try expectEqual(table.price(for: "kimi-k3")?.inputPerM, 3)
        let free = table.resolution(for: "big-pickle", provider: "opencode")
        try expectEqual(free.price?.inputPerM, 0)
    }

    t.test("自定义代理 provider：按模型名推断厂商并标注") {
        let table = try makeTable()
        let proxy = table.resolution(for: "gpt-5.6-sol", provider: "aftership-codex-proxy")
        try expectEqual(proxy.price?.inputPerM, 4)
        try expectEqual(proxy.vendorInferred, true)
    }

    t.test("手写表前缀兜底标估算") {
        let table = try makeTable()
        let mini = table.resolution(for: "gpt-5-codex-mini", provider: nil)
        try expectEqual(mini.price?.inputPerM, 1.25)
        try expectEqual(mini.estimated, true)
    }

    t.test("用户别名表：把自定义 provider 指到订阅") {
        let table = try makeTable(aliases: [
            "my-proxy": ProviderAlias(vendor: "openai", billing: .subscription),
        ])
        let row = table.resolution(for: "gpt-6-sol", provider: "my-proxy")
        try expectEqual(row.subscription, true)
        try expectEqual(row.vendorInferred, false)
        try expectEqual(row.price?.inputPerM, 2)
    }

    t.test("黄金表：本地账本里的真实模型名") {
        let table = try makeTable()
        // (模型, provider, 期望输入价；nil = 未定价)
        let golden: [(String, String?, Double?)] = [
            ("claude-fable-5", nil, 10), ("claude-fable-5-1", nil, 10),
            ("claude-haiku-4-5-20251001", nil, 1), ("claude-opus-4-7", nil, 5),
            ("claude-opus-4-8", nil, 5), ("claude-opus-5", nil, 5),
            ("claude-opus-5-5", nil, 4), ("claude-sonnet-5", nil, 2),
            ("codex-auto-review", nil, nil), ("gpt-5-codex", nil, 1.25),
            ("gpt-5.1-codex-max", nil, 1.25), ("gpt-5.2", nil, 1.75),
            ("gpt-5.3-codex", nil, 1.75), ("gpt-5.4", nil, 2.5), ("gpt-5.5", nil, 5),
            ("gpt-5.6-luna", nil, 0.2), ("gpt-5.6-sol", "openai", 4),
            ("gpt-5.6-terra", nil, 2), ("gpt-6-astra", nil, 10), ("gpt-6-sol", nil, 2),
            ("cursor/claude-4.5-opus-high-thinking", nil, nil), ("cursor/default", nil, nil),
            ("gemini-3-flash-preview", nil, 0.5), ("gemini-3.5-flash", nil, 1.5),
            ("kimi-code/k3", nil, 3), ("kimi-code/k3-256k", nil, 3),
            ("kimi-code/kimi-for-coding", nil, nil), ("moonshot-cn/kimi-k3", nil, 3),
            ("ark-code-latest", "volcengine-agent-plan", nil),
            ("glm-5.2", "volcengine-agent-plan", 1.4), ("glm-5.3", "zhipuai-coding-plan", 1.4),
            ("kimi-k2.7-code", "volcengine-agent-plan", 0.95), ("k3", "kimi-for-coding", 3),
            ("mimo-v2.6-pro", "opencode-go", 0.435), ("minimax-m3", "volcengine-agent-plan", 0.3),
            ("qwen3.7-max", nil, 2.5), ("qwen3.6-plus", nil, 0.5),
            ("deepseek-v4-flash", nil, 0.3), ("glm-5.3", "builtin:bigmodel", 1.4),
        ]
        for (model, provider, expected) in golden {
            let got = table.resolution(for: model, provider: provider).price?.inputPerM
            try expectEqual(got, expected, "\(model) @\(provider ?? "-")")
        }
    }

    t.suite("PricingCatalogStore 层级与序列化")

    t.test("缓存/快照往返编码无损") {
        let catalog = try sampleCatalog()
        let decoded = try PricingCatalogStore.decode(PricingCatalogStore.encode(catalog))
        try expectEqual(decoded, catalog)
    }

    t.test("逐来源取较新者：新快照胜旧缓存，损坏缓存落到快照") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-pricing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var fresh = try sampleCatalog()
        fresh.litellm["gpt-6-sol"] = CatalogPrice(inputPerM: 7, outputPerM: 7)
        fresh.litellmMeta?.fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try sampleCatalog()
        let snapshotURL = dir.appendingPathComponent("snapshot.json")
        let cacheURL = dir.appendingPathComponent("cache.json")
        try PricingCatalogStore.encode(fresh).write(to: snapshotURL)
        try PricingCatalogStore.encode(old).write(to: cacheURL)
        let store = PricingCatalogStore()
        store.loadIfNeeded(paths: PricingPaths(
            bundledTable: nil, bundledSnapshot: snapshotURL, cache: cacheURL, override: nil))
        try expectEqual(store.current.price(for: "gpt-6-sol")?.inputPerM, 7)

        try Data("garbage".utf8).write(to: cacheURL)
        let second = PricingCatalogStore()
        second.loadIfNeeded(paths: PricingPaths(
            bundledTable: nil, bundledSnapshot: snapshotURL, cache: cacheURL, override: nil))
        try expectEqual(second.current.price(for: "gpt-6-sol")?.inputPerM, 7)
        try expectEqual(second.currentOrigin, .snapshot)
    }

    t.test("install 热替换并递增 revision") {
        let store = PricingCatalogStore()
        store.loadIfNeeded(paths: PricingPaths(
            bundledTable: nil, bundledSnapshot: nil, cache: nil, override: nil))
        let before = store.revision
        try expect(store.current.price(for: "gpt-6-sol") == nil)
        store.install(catalog: try sampleCatalog())
        try expect(store.revision > before)
        try expectEqual(store.current.price(for: "gpt-6-sol")?.inputPerM, 2)
    }

    t.test("并发解析 + 热替换不崩、结果一致") {
        let store = PricingCatalogStore()
        store.loadIfNeeded(paths: PricingPaths(
            bundledTable: nil, bundledSnapshot: nil, cache: nil, override: nil))
        let catalog = try sampleCatalog()
        store.install(catalog: catalog)
        let lock = NSLock()
        var mismatches = 0
        DispatchQueue.concurrentPerform(iterations: 2000) { index in
            if index % 100 == 0 { store.install(catalog: catalog) }
            let price = store.current.price(for: "gpt-5.6-sol")?.inputPerM
            if price != 4 {
                lock.lock(); mismatches += 1; lock.unlock()
            }
        }
        try expectEqual(mismatches, 0)
    }

    t.suite("CatalogRefresher")

    let litellmBody = try? fixtureData("pricing/litellm-sample.json")
    let modelsDevBody = try? fixtureData("pricing/modelsdev-sample.json")
    let minimums = (litellm: 10, modelsDev: 5)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    t.test("主源失败走镜像；两源都成功记 etag") {
        var hosts: [String] = []
        let outcome = CatalogRefresher.refresh(previous: .empty, now: now, minimums: minimums) { request in
            let host = request.url?.host ?? ""
            hosts.append(host)
            if host == "raw.githubusercontent.com" { throw URLError(.timedOut) }
            let body = host == "models.dev" ? modelsDevBody! : litellmBody!
            return CatalogFetchResponse(status: 200, body: body, headers: ["ETag": "\"v1\""])
        }
        try expectEqual(outcome.succeeded, true)
        try expectEqual(outcome.changed, true)
        try expect(hosts.contains("cdn.jsdelivr.net"), "\(hosts)")
        try expectEqual(outcome.catalog.litellmMeta?.etag, "\"v1\"")
        try expect(outcome.catalog.litellm["gpt-6-sol"] != nil)
    }

    t.test("304 保留数据、刷新 fetchedAt、带条件头") {
        let previous = try sampleCatalog()
        var sawConditional = true
        var withEtag = previous
        withEtag.litellmMeta?.etag = "\"v1\""
        withEtag.modelsDevMeta?.etag = "\"m1\""
        let outcome = CatalogRefresher.refresh(previous: withEtag, now: now, minimums: minimums) { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == nil { sawConditional = false }
            return CatalogFetchResponse(status: 304, body: Data())
        }
        try expect(sawConditional)
        try expectEqual(outcome.changed, false)
        try expectEqual(outcome.succeeded, true)
        try expectEqual(outcome.catalog.litellm, previous.litellm)
        try expectEqual(outcome.catalog.litellmMeta?.fetchedAt, now)
    }

    t.test("全部失败 / 坏数据：保留上一份，不清空价格") {
        let previous = try sampleCatalog()
        let offline = CatalogRefresher.refresh(previous: previous, now: now, minimums: minimums) { _ in
            throw URLError(.notConnectedToInternet)
        }
        try expectEqual(offline.succeeded, false)
        try expectEqual(offline.catalog, previous)
        try expectEqual(offline.errors.count, 2)
        let garbage = CatalogRefresher.refresh(previous: previous, now: now, minimums: minimums) { _ in
            CatalogFetchResponse(status: 200, body: Data("{\"x\":1}".utf8))
        }
        try expectEqual(garbage.succeeded, false)
        try expectEqual(garbage.catalog.litellm, previous.litellm)
    }

    t.test("退避序列与到期判断") {
        try expectEqual(CatalogRefresher.retryDelay(afterFailures: 1), 60)
        try expectEqual(CatalogRefresher.retryDelay(afterFailures: 3), 1800)
        try expectEqual(CatalogRefresher.retryDelay(afterFailures: 99), 21600)
        try expect(CatalogRefresher.isDue(lastSuccess: nil, now: now))
        try expect(!CatalogRefresher.isDue(lastSuccess: now.addingTimeInterval(-3600), now: now))
        try expect(CatalogRefresher.isDue(lastSuccess: now.addingTimeInterval(-90_000), now: now))
    }

    t.suite("provider 入库与按模型合并")

    t.test("旧库补列、按 provider 拆分聚合、回填只动 NULL 行") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-provider-\(UUID().uuidString)/test.sqlite")
        let store = try EurekaStore(path: url)
        let ts = Date(timeIntervalSince1970: 1_790_000_000)
        try store.usage.insert([
            UsageRecord(source: .opencode, model: "glm-5.2", sessionId: "s1", timestamp: ts,
                        inputTokens: 100, outputTokens: 10, provider: "volcengine-agent-plan"),
            UsageRecord(source: .opencode, model: "glm-5.2", sessionId: "s2", timestamp: ts,
                        inputTokens: 200, outputTokens: 20),
        ])
        let rows = try store.usage.totalsByModel(
            from: ts.addingTimeInterval(-1), to: ts.addingTimeInterval(1))
        try expectEqual(rows.count, 2)
        try store.usage.backfillProvider(
            source: .opencode, sessionId: "s2", model: "glm-5.2",
            ts: ts.timeIntervalSince1970, provider: "zhipuai")
        try store.usage.backfillProvider(
            source: .opencode, sessionId: "s1", model: "glm-5.2", ts: nil, provider: "overwrite?")
        let providers = Set(try store.usage.distinctModels().compactMap(\.provider))
        try expectEqual(providers, ["volcengine-agent-plan", "zhipuai"])
    }

    t.test("看板汇总：同名模型的多个 provider 合并成一行，费用相加") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-merge-\(UUID().uuidString)/test.sqlite")
        let store = try EurekaStore(path: url)
        let now = Date()
        try store.usage.insert([
            UsageRecord(source: .opencode, model: "glm-5.2", timestamp: now,
                        inputTokens: 1_000_000, outputTokens: 0, provider: "volcengine-agent-plan"),
            UsageRecord(source: .opencode, model: "glm-5.2", timestamp: now,
                        inputTokens: 1_000_000, outputTokens: 0, provider: "zhipuai"),
        ])
        let summary = try UsageAggregator.summarize(
            store: store, pricing: try makeTable(), now: now.addingTimeInterval(1))
        let source = try expectSome(summary.today.first)
        try expectEqual(source.models.count, 1)
        try expectEqual(source.models.first?.totalTokens, 2_000_000)
        try expect(abs((source.models.first?.costUSD ?? 0) - 2.8) < 0.0001, "\(source.models)")
    }
}
