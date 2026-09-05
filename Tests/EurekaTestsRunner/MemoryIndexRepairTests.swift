import EurekaIngest
import EurekaKit
import Foundation

func memoryIndexRepairTests(_ t: TestRunner) {
    t.suite("MemoryIndexRepair · 索引漂移一键修复")

    func entry(
        _ file: String, title: String? = nil, summary: String? = nil
    ) -> MemoryEntry {
        MemoryEntry(
            source: .claude, scope: "demo",
            path: "/lib/memory/\(file)",
            sizeBytes: 1, modifiedAt: Date(timeIntervalSince1970: 0),
            title: title, summary: summary, libraryKey: "claude:demo")
    }

    t.test("未收录条目补录到文末（带/不带摘要两种行格式）") {
        let index = """
        # Memory Index

        - [已收录](indexed.md) — 旧钩子
        """
        let outcome = MemoryIndexRepair.repair(
            indexText: index,
            entries: [
                entry("indexed.md"),
                entry("miss-a.md", summary: "钩子 A"),
                entry("miss-b.md"),
            ])
        try expect(outcome != nil, "有未收录条目必须给出修复")
        try expectEqual(outcome?.addedCount, 2)
        try expectEqual(outcome?.removedCount, 0)
        try expect(
            outcome!.text.contains("- [miss-a](miss-a.md) — 钩子 A"),
            "带摘要的补录行格式不对：\(outcome!.text)")
        try expect(
            outcome!.text.contains("- [miss-b](miss-b.md)"),
            "无摘要的补录行格式不对")
        try expect(outcome!.text.hasSuffix("\n"), "修复后必须以换行结尾")
        try expect(outcome!.text.contains("- [已收录](indexed.md) — 旧钩子"), "已有行不能被动")
    }

    t.test("悬空引用行被删除，其余行原样保留") {
        let index = """
        # Memory Index

        - [还在](alive.md) — 钩子
        - [没了](gone.md) — 指向空气
        普通正文行提到 (gone.md) 不是列表项，不能删
        """
        let outcome = MemoryIndexRepair.repair(
            indexText: index, entries: [entry("alive.md")])
        try expectEqual(outcome?.removedCount, 1)
        try expectEqual(outcome?.addedCount, 0)
        try expect(!outcome!.text.contains("- [没了](gone.md)"), "悬空行必须删除")
        try expect(outcome!.text.contains("- [还在](alive.md)"), "有效行必须保留")
        try expect(outcome!.text.contains("普通正文行"), "非列表行即使含悬空链接也不能删")
    }

    t.test("frontmatter 标题命中即算收录（与 unindexedEntries 判据一致）") {
        // 文件名 real-file.md 没被链接，但索引里链的是它的 frontmatter name
        let index = "- [别名](my-alias.md)\n"
        let outcome = MemoryIndexRepair.repair(
            indexText: index,
            entries: [entry("real-file.md", title: "my_alias")])
        // normalizeKey 把 _ 归一成 -，标题命中 → 无需补录；my-alias.md 目标也因
        // 标题键命中不算悬空
        try expect(outcome == nil, "标题已被收录时不应有任何修复：\(String(describing: outcome))")
    }

    t.test("无漂移返回 nil（幂等：修复结果再跑一遍无动作）") {
        let index = """
        # Memory Index

        - [a](a.md) — 钩子
        """
        let entries = [entry("a.md"), entry("b.md", summary: "补")]
        let first = MemoryIndexRepair.repair(indexText: index, entries: entries)
        try expect(first != nil)
        let second = MemoryIndexRepair.repair(indexText: first!.text, entries: entries)
        try expect(second == nil, "修复后的文本必须是稳定态：\(String(describing: second))")
    }

    t.test("同一行悬空+有效链接并存时保留（保守不删）") {
        let index = "- [组合](alive.md) 兼提 (gone.md)\n"
        let outcome = MemoryIndexRepair.repair(
            indexText: index, entries: [entry("alive.md")])
        try expect(
            outcome == nil || outcome!.text.contains("alive.md"),
            "含有效链接的行不能被整行删除")
    }
}
