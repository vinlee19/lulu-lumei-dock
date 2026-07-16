import EurekaKit
import Foundation

func markdownBlockTests(_ t: TestRunner) {
    t.suite("MarkdownBlockParser")

    t.test("围栏代码块：语言标识、代码内 #/- 不误判、闭合后继续解析") {
        let blocks = MarkdownBlockParser.parse("""
        前言
        ```swift
        # 这是注释不是标题
        - 这不是列表
        let x = 1
        ```
        后记
        """)
        try expectEqual(blocks.count, 3)
        try expectEqual(blocks[0], .paragraph("前言"))
        try expectEqual(blocks[1], .codeBlock(
            language: "swift", code: "# 这是注释不是标题\n- 这不是列表\nlet x = 1"))
        try expectEqual(blocks[2], .paragraph("后记"))
    }

    t.test("未闭合围栏容错：收到文末，内容不丢") {
        let blocks = MarkdownBlockParser.parse("```\ncode line 1\ncode line 2")
        try expectEqual(blocks, [.codeBlock(language: nil, code: "code line 1\ncode line 2")])
    }

    t.test("标题层级与非标题（无空格/超 6 级）") {
        let blocks = MarkdownBlockParser.parse("""
        # 一级
        ### 三级
        #无空格不是标题
        ####### 七个井号不是标题
        """)
        try expectEqual(blocks[0], .heading(level: 1, text: "一级"))
        try expectEqual(blocks[1], .heading(level: 3, text: "三级"))
        try expectEqual(blocks[2], .paragraph("#无空格不是标题\n####### 七个井号不是标题"))
    }

    t.test("列表：无序/有序/缩进层级") {
        let blocks = MarkdownBlockParser.parse("""
        - 甲
        * 乙
        1. 第一
        2) 第二
          - 缩进一级
        """)
        try expectEqual(blocks[0], .listItem(ordered: false, index: 0, text: "甲", indent: 0))
        try expectEqual(blocks[1], .listItem(ordered: false, index: 0, text: "乙", indent: 0))
        try expectEqual(blocks[2], .listItem(ordered: true, index: 1, text: "第一", indent: 0))
        try expectEqual(blocks[3], .listItem(ordered: true, index: 2, text: "第二", indent: 0))
        try expectEqual(blocks[4], .listItem(ordered: false, index: 0, text: "缩进一级", indent: 1))
    }

    t.test("引用合并 + 分隔线 + 段落换行保留") {
        let blocks = MarkdownBlockParser.parse("""
        > 引用一
        > 引用二
        ---
        普通段落第一行
        第二行
        """)
        try expectEqual(blocks[0], .quote("引用一\n引用二"))
        try expectEqual(blocks[1], .divider)
        try expectEqual(blocks[2], .paragraph("普通段落第一行\n第二行"))
    }

    t.test("空文本与纯空白") {
        try expectEqual(MarkdownBlockParser.parse(""), [])
        try expectEqual(MarkdownBlockParser.parse("\n\n  \n"), [])
    }

    t.test("纯文本消息：单一 paragraph 原样保留") {
        let text = "你好，帮我看个问题。这里有 `code` 和 **bold**。"
        try expectEqual(MarkdownBlockParser.parse(text), [.paragraph(text)])
    }

    t.test("GFM 表格：表头 + 分隔行 + 数据行 → table 块") {
        let blocks = MarkdownBlockParser.parse("""
        前言
        | 来源 | 说明 |
        |---|---|
        | **Claude** | `tool_use` |
        | Codex | function_call |
        后记
        """)
        try expectEqual(blocks.count, 3)
        try expectEqual(blocks[0], .paragraph("前言"))
        try expectEqual(blocks[1], .table(
            header: ["来源", "说明"],
            rows: [["**Claude**", "`tool_use`"], ["Codex", "function_call"]]))
        try expectEqual(blocks[2], .paragraph("后记"))
    }

    t.test("无分隔行的 | 文本 → 退回 paragraph（不误判表格）") {
        let blocks = MarkdownBlockParser.parse("a | b | c\nd | e | f")
        try expectEqual(blocks, [.paragraph("a | b | c\nd | e | f")])
    }

    t.test("表格列数不齐容错：短行照收（渲染层补空）") {
        let blocks = MarkdownBlockParser.parse("""
        | A | B | C |
        |---|---|---|
        | 1 | 2 |
        """)
        try expectEqual(blocks, [.table(
            header: ["A", "B", "C"], rows: [["1", "2"]])])
    }
}
