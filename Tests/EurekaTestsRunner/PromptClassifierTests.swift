import EurekaKit
import Foundation

func promptClassifierTests(_ t: TestRunner) {
    t.suite("PromptClassifier · 复用价值分类")

    t.test("长度边界：12/13 分琐碎与追问，40/41 分追问与指令") {
        try expectEqual(PromptClassifier.classify("一二三四五六七八九十一二"), .trivial)   // 12
        try expectEqual(PromptClassifier.classify("一二三四五六七八九十一二三"), .followup) // 13
        let forty = String(repeating: "字", count: 40)
        let fortyOne = String(repeating: "字", count: 41)
        try expectEqual(PromptClassifier.classify(forty), .followup)
        try expectEqual(PromptClassifier.classify(fortyOne), .instruction)
    }

    t.test("琐碎词表：超过长度阈值的习惯短语也算琐碎（大小写不敏感）") {
        try expectEqual(PromptClassifier.classify("Continue"), .trivial)
        try expectEqual(PromptClassifier.classify("go ahead"), .trivial)
        try expectEqual(PromptClassifier.classify("继续"), .trivial)
    }

    t.test("长粘贴 vs 手写长指令：markdown 结构是分界") {
        // 无结构的 2000+ 字符 = 粘贴
        let paste = (0..<80).map { "2026-08-24 10:00:\($0) INFO worker heartbeat ok padding" }
            .joined(separator: "\n")
        try expect(paste.count >= 2000, "样例长度不足")
        try expectEqual(PromptClassifier.classify(paste), .paste)
        // 带标题与列表的 2000+ 字符 = 指令（用户手写的长需求）
        let spec = "# 目标\n" + (0..<60).map {
            "- 需求点 \($0)：把分页逻辑改成游标式并保持兼容，注意越界回退与空页语义不能变"
        }.joined(separator: "\n")
        try expect(spec.count >= 2000, "样例长度不足")
        try expectEqual(PromptClassifier.classify(spec), .instruction)
    }

    t.test("注入产物与裸斜杠命令判 noise；路径与正文中的 / 不误伤") {
        try expectEqual(PromptClassifier.classify("<command-name>/plan</command-name>"), .noise)
        try expectEqual(PromptClassifier.classify("<local-command-stdout>Enabled</local-command-stdout>"), .noise)
        try expectEqual(PromptClassifier.classify("<bash-input>ls</bash-input>"), .noise)
        try expectEqual(PromptClassifier.classify("<environment_context>cwd=/x</environment_context>"), .noise)
        try expectEqual(PromptClassifier.classify("/compact"), .noise)
        try expectEqual(PromptClassifier.classify("/effort high"), .noise)
        // 第二个 / = 路径，不是斜杠命令
        try expect(PromptClassifier.classify("/usr/bin/env 有什么用，请展开讲讲细节") != .noise)
        // 不以 / 开头的正常提问（26 字符落在追问档，但绝不是噪音）
        try expectEqual(
            PromptClassifier.classify("看下 /tmp/x.log 里的报错并深入分析根因给出修复"), .followup)
    }

    t.test("指纹：大小写/空白归一；只取前 512 字符") {
        try expectEqual(
            PromptClassifier.normalizedFingerprint("Implement  the\tPlan."),
            PromptClassifier.normalizedFingerprint("implement the plan."))
        let longA = String(repeating: "a", count: 600)
        let longB = String(repeating: "a", count: 512) + String(repeating: "b", count: 88)
        try expectEqual(
            PromptClassifier.normalizedFingerprint(longA),
            PromptClassifier.normalizedFingerprint(longB),
            "512 之后的差异不参与指纹")
    }

    t.test("入库截断：超限加标记，未超限原样") {
        let short = "正常提问"
        try expectEqual(PromptClassifier.truncateForStorage(short), short)
        let long = String(repeating: "x", count: 70000)
        let truncated = PromptClassifier.truncateForStorage(long)
        try expect(truncated.hasSuffix("…[已截断]"))
        try expect(truncated.count < 66000)
    }

    t.suite("PromptGrouping · 高频重复聚类")

    func entry(
        _ id: String, text: String, cwd: String? = "/w/proj", at seconds: Double
    ) -> PromptEntry {
        PromptEntry(
            id: id, source: .claude, sessionId: "s", messageIdx: 0,
            text: text, timestamp: Date(timeIntervalSince1970: seconds), cwd: cwd,
            firstSeen: Date(timeIntervalSince1970: seconds))
    }

    t.test("minCount 起组、代表条目取最新、跨项目计数、按次数降序") {
        let entries = [
            entry("a1", text: "Implement the plan.", cwd: "/w/p1", at: 100),
            entry("a2", text: "implement  the plan.", cwd: "/w/p2", at: 300),
            entry("a3", text: "IMPLEMENT THE PLAN.", cwd: "/w/p1", at: 200),
            entry("b1", text: "只出现两次的提问需要凑够十三个字符长", at: 100),
            entry("b2", text: "只出现两次的提问需要凑够十三个字符长", at: 200),
            entry("c1", text: "孤条", at: 100),
        ]
        let groups = PromptGrouping.groups(from: entries, minCount: 3) { _ in true }
        try expectEqual(groups.count, 1, "minCount=3 时两次的组不成立")
        try expectEqual(groups[0].count, 3)
        try expectEqual(groups[0].representative.id, "a2", "代表条目应是最新的一条")
        try expectEqual(groups[0].projectCount, 2)
        try expectEqual(groups[0].memberIds.first, "a2")

        let loose = PromptGrouping.groups(from: entries, minCount: 2) { _ in true }
        try expectEqual(loose.count, 2)
        try expectEqual(loose[0].count, 3, "组按出现次数降序")
    }

    t.test("keeping 过滤：被排除的条目不参与聚类") {
        let entries = [
            entry("n1", text: "继续", at: 100),
            entry("n2", text: "继续", at: 200),
            entry("n3", text: "继续", at: 300),
        ]
        let groups = PromptGrouping.groups(from: entries, minCount: 2) { candidate in
            PromptClassifier.classify(candidate.text) != .trivial
        }
        try expect(groups.isEmpty, "琐碎短语不该成组")
    }

    t.test("组内移除成员：计数/代表/项目数更新并重排，跌破 minCount 整组消失") {
        let entries = [
            entry("a1", text: "Implement the plan.", cwd: "/w/p1", at: 100),
            entry("a2", text: "implement the plan.", cwd: "/w/p2", at: 300),
            entry("a3", text: "IMPLEMENT THE PLAN.", cwd: "/w/p1", at: 200),
            entry("a4", text: "implement the plan.", cwd: "/w/p1", at: 50),
            entry("b1", text: "跑一遍全部测试并汇报失败原因", cwd: "/w/p1", at: 100),
            entry("b2", text: "跑一遍全部测试并汇报失败原因", cwd: "/w/p1", at: 200),
            entry("b3", text: "跑一遍全部测试并汇报失败原因", cwd: "/w/p1", at: 300),
        ]
        let byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let groups = PromptGrouping.groups(from: entries, minCount: 3) { _ in true }
        try expectEqual(groups.map(\.count), [4, 3])

        // 摘掉 a 组的代表 a2（最新的一条，也是唯一落在 p2 项目的一条）
        let afterOne = PromptGrouping.removing(
            memberId: "a2", from: groups, minCount: 3) { byId[$0] }
        try expectEqual(afterOne.map(\.count), [3, 3])
        let a = afterOne.first { $0.fingerprint == groups[0].fingerprint }
        try expectEqual(a?.representative.id, "a3", "代表换成剩余成员里最新的一条")
        try expectEqual(a?.projectCount, 1, "项目数按剩余成员重算")
        try expectEqual(a?.memberIds, ["a3", "a1", "a4"])
        // 同为 3 次：代表更新的排前 → b 组（代表 b3 @300）超到 a 组（代表 a3 @200）前面
        try expectEqual(afterOne.map { $0.representative.id }, ["b3", "a3"], "与 groups(from:) 同序")

        // 再摘一条 → a 组只剩 2 条，跌破 minCount 整组消失；不在任何组里的 id 是 no-op
        let afterTwo = PromptGrouping.removing(
            memberId: "a1", from: afterOne, minCount: 3) { byId[$0] }
        try expectEqual(afterTwo.map(\.fingerprint), [groups[1].fingerprint])
        let untouched = PromptGrouping.removing(
            memberId: "zzz", from: afterTwo, minCount: 3) { byId[$0] }
        try expectEqual(untouched, afterTwo)
    }

    t.suite("PromptLaunchCommand · 终端启动命令")

    t.test("白名单：只有 claude/codex 有 CLI；命令拼接含 cd 前缀") {
        try expectEqual(PromptLaunchCommand.cliExecutable(for: .claude), "claude")
        try expectEqual(PromptLaunchCommand.cliExecutable(for: .codex), "codex")
        try expect(PromptLaunchCommand.cliExecutable(for: .cursor) == nil)
        try expect(PromptLaunchCommand.cliExecutable(for: .gemini) == nil)

        try expectEqual(
            PromptLaunchCommand.build(cli: "claude", cwd: "/w/my proj", prompt: "修 bug"),
            "cd '/w/my proj' && claude '修 bug'")
        try expectEqual(
            PromptLaunchCommand.build(cli: "codex", cwd: nil, prompt: "修 bug"),
            "codex '修 bug'")
    }

    t.test("shellSingleQuote 注入安全：引号/命令替换/分号/反引号全部字面量") {
        // 单引号：'…' 中断重接
        try expectEqual(
            PromptLaunchCommand.shellSingleQuote("it's"), "'it'\\''s'")
        // $() 反引号 分号 —— 单引号内全是字面量，不需要额外转义，但必须完整包裹
        let hostile = "x; rm -rf ~; $(whoami) `id`"
        let quoted = PromptLaunchCommand.shellSingleQuote(hostile)
        try expect(quoted.hasPrefix("'") && quoted.hasSuffix("'"))
        try expect(quoted.contains("$(whoami)"), "单引号内保持字面量即安全")
        // 换行 → $'\n' 拼接（AppleScript 字面量放不下裸换行）；\r 丢弃
        try expectEqual(
            PromptLaunchCommand.shellSingleQuote("a\r\nb"), "'a'$'\\n''b'")
        try expect(!PromptLaunchCommand.shellSingleQuote("a\nb").contains("\n"),
            "输出必须是单行")
    }
}
