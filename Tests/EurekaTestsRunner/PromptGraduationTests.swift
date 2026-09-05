import EurekaInstall
import EurekaKit
import Foundation

func promptGraduationTests(_ t: TestRunner) {
    t.suite("PromptInstructionDestination · 记忆毕业落点")

    t.test("落点：claude 追加 ~/.claude/CLAUDE.md、codex 追加 AGENTS.md，都落指令页；其余源不开放") {
        // 官方文档（code.claude.com/docs/en/memory 与 /claude-directory）里 Claude Code 加载的
        // 只有 CLAUDE.md 系列、.claude/rules/ 与 projects/<project>/memory/ 自动记忆 ——
        // 没有 ~/.claude/memories/，写进去 Claude 永远读不到，所以 claude 分支必须走 CLAUDE.md
        try expectEqual(
            PromptInstructionDestination.destination(for: .claude), .claudeUserInstructions)
        try expectEqual(PromptInstructionDestination.destination(for: .codex), .codexAgentsFile)
        try expectEqual(PromptInstructionDestination.destination(for: .kimi), nil)
        try expectEqual(PromptInstructionDestination.supportedSources, [.claude, .codex])
        for destination in [PromptInstructionDestination.claudeUserInstructions, .codexAgentsFile] {
            try expectEqual(
                destination.knowledgeKind, "instruction",
                "两个落点在索引里都是指令类，reveal 必须落到指令页")
        }
        try expectEqual(PromptInstructionDestination.claudeUserInstructions.fileLabel, "~/.claude/CLAUDE.md")
        try expectEqual(PromptInstructionDestination.codexAgentsFile.fileLabel, "~/.codex/AGENTS.md")
        try expectEqual(PromptInstructionDestination.claudeUserInstructions.defaultHeader, "# CLAUDE.md")
        try expectEqual(PromptInstructionDestination.codexAgentsFile.defaultHeader, "# AGENTS.md")
    }

    t.suite("PromptGraduationDocument · 毕业文档生成")

    t.test("SKILL.md：name 取 slug，description 压成单行并转义引号/反斜杠，正文结尾单个换行") {
        let doc = PromptGraduationDocument.skill(
            slug: "fix-paging",
            description: "修 \"分页\" 越界\n第二行 C:\\tmp",
            body: "帮我修分页越界\n并补测试")
        let expected = "---\nname: fix-paging\n"
            + "description: \"修 \\\"分页\\\" 越界 第二行 C:\\\\tmp\"\n---\n\n"
            + "帮我修分页越界\n并补测试\n"
        try expectEqual(doc, expected)

        let trailing = PromptGraduationDocument.skill(
            slug: "s", description: "d", body: "正文\n\n")
        try expect(trailing.hasSuffix("\n\n正文\n"), "正文尾部的多余换行压成一个")
    }

    t.test("追加指令节：无文件起默认标题；有文件时原文与新节之间恰好一个空行") {
        try expectEqual(
            PromptGraduationDocument.appendingInstructionSection(
                to: nil, title: "分页", body: "正文"),
            "# AGENTS.md\n\n## 分页\n\n正文\n")
        try expectEqual(
            PromptGraduationDocument.appendingInstructionSection(
                to: "# AGENTS.md\n已有内容", title: "分页", body: "正文"),
            "# AGENTS.md\n已有内容\n\n## 分页\n\n正文\n")
        try expectEqual(
            PromptGraduationDocument.appendingInstructionSection(
                to: "# AGENTS.md\n已有内容\n\n\n", title: "分页", body: "正文"),
            "# AGENTS.md\n已有内容\n\n## 分页\n\n正文\n",
            "多余的尾部空行压成一个空行")
        try expectEqual(
            PromptGraduationDocument.appendingInstructionSection(
                to: nil, title: "分页", body: "正文", defaultHeader: "# CLAUDE.md"),
            "# CLAUDE.md\n\n## 分页\n\n正文\n",
            "Claude 的 ~/.claude/CLAUDE.md 不存在时以自己的标题起头")
    }

    t.test("Codex 指令文件：override 存在时追加到 override，否则 AGENTS.md") {
        try expectEqual(
            PromptGraduationDocument.codexInstructionFileName(overrideExists: true),
            "AGENTS.override.md")
        try expectEqual(
            PromptGraduationDocument.codexInstructionFileName(overrideExists: false),
            "AGENTS.md")
    }
}
