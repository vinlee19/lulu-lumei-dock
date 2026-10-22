import EurekaIngest
import EurekaKit
import Foundation

func sessionJumpTests(_ t: TestRunner) {
    t.suite("打开会话 · 跳转目标与桌面版直达链接")

    t.test("直达链接：按桌面版的格式拼 URL，id 不合格式就不出 URL") {
        let claude = SessionAppLink.claudeDesktop(
            localSessionId: "local_cb9f0cfd-343a-4d08-bd33-c76e9f9dde7f")
        try expectEqual(
            claude.url?.absoluteString,
            "claude://code/continue?session=local_cb9f0cfd-343a-4d08-bd33-c76e9f9dde7f")
        try expectEqual(claude.bundleId, "com.anthropic.claudefordesktop")
        let codex = SessionAppLink.codexDesktop(threadId: "0199aaaa-0000-7000-8000-000000000001")
        try expectEqual(codex.url?.absoluteString, "codex://threads/0199aaaa-0000-7000-8000-000000000001")
        try expectEqual(codex.bundleId, "com.openai.codex")

        try expect(SessionAppLink.claudeDesktop(localSessionId: "cb9f0cfd").url == nil, "缺 local_ 前缀")
        try expect(SessionAppLink.claudeDesktop(localSessionId: "local_").url == nil, "前缀后为空")
        try expect(
            SessionAppLink.claudeDesktop(localSessionId: "local_a&next=/settings").url == nil,
            "含 URL 特殊字符")
        try expect(
            SessionAppLink.claudeDesktop(localSessionId: "local_" + String(repeating: "a", count: 65))
                .url == nil, "超过 64 位")
        try expect(SessionAppLink.codexDesktop(threadId: "../settings").url == nil, "不是 UUID")
    }

    t.test("跳转目标：hook 采到的宿主不是链接所在应用时去宿主，否则链接优先于探测结果") {
        let link = SessionAppLink.claudeDesktop(localSessionId: "local_abc")
        let iterm = TerminalBinding(app: "iTerm.app", bundleId: "com.googlecode.iterm2", origin: .hook)
        let desktop = TerminalBinding(bundleId: "com.anthropic.claudefordesktop", origin: .hook)
        let probed = TerminalBinding(app: "iTerm.app", bundleId: "com.googlecode.iterm2", origin: .probe)

        try expectEqual(
            SessionJumpTarget.resolve(terminal: iterm, link: link), .hostApp(iterm),
            "桌面版会话被 resume 到了终端：去终端")
        try expectEqual(
            SessionJumpTarget.resolve(terminal: desktop, link: link), .appLink(link),
            "hook 采到的宿主就是桌面版：直达会话")
        try expectEqual(
            SessionJumpTarget.resolve(terminal: probed, link: link), .appLink(link),
            "探测按 cwd 匹配可能认错，排在链接之后")
        try expectEqual(SessionJumpTarget.resolve(terminal: nil, link: link), .appLink(link))
        try expectEqual(SessionJumpTarget.resolve(terminal: probed, link: nil), .hostApp(probed))
        try expect(SessionJumpTarget.resolve(terminal: nil, link: nil) == nil, "无处可去不出按钮")
    }

    /// Looks links up in the fixture's Desktop session dir and rollout tree
    func resolver() throws -> (AgentSource, String) -> SessionAppLink? {
        let desktopRoot = try fixtureURL("claude-desktop-sessions")
        let codexRoot = try fixtureURL("codex-desktop-sessions")
        return { source, sessionId in
            SessionAppLinkResolver.resolve(
                source: source, sessionId: sessionId,
                claudeDesktopRoot: desktopRoot, codexSessionsRoot: codexRoot)
        }
    }

    t.test("Claude 桌面版：按 cliSessionId 找到 local_ 会话，归档的和 CLI 会话都没有链接") {
        let resolve = try resolver()
        try expectEqual(
            resolve(.claude, "11111111-1111-4111-8111-111111111111"),
            .claudeDesktop(localSessionId: "local_aaaa0001-0000-4000-8000-000000000001"))
        try expect(
            resolve(.claude, "22222222-2222-4222-8222-222222222222") == nil,
            "已归档：桌面版的深链接找不到它")
        try expect(
            resolve(.claude, "99999999-9999-4999-8999-999999999999") == nil,
            "不在桌面版里的就是终端里的 CLI 会话")
        try expect(resolve(.claude, "not-a-uuid") == nil, "会话 id 不是 UUID 不查")
    }

    t.test("Claude 桌面版：cliSessionId 不在文件头部时整读兜底；只在别的字段里出现不算") {
        let resolve = try resolver()
        try expectEqual(
            resolve(.claude, "33333333-3333-4333-8333-333333333333"),
            .claudeDesktop(localSessionId: "local_aaaa0003-0000-4000-8000-000000000003"))
        try expect(
            resolve(.claude, "55555555-5555-4555-8555-555555555555") == nil,
            "派生来源 id 只是字节命中，字段校验后排除")
    }

    t.test("Codex 桌面版：rollout 的 originator 是 Codex Desktop 才给链接") {
        let resolve = try resolver()
        try expectEqual(
            resolve(.codex, "0199aaaa-0000-7000-8000-000000000001"),
            .codexDesktop(threadId: "0199aaaa-0000-7000-8000-000000000001"))
        try expect(resolve(.codex, "0199aaaa-0000-7000-8000-000000000002") == nil, "CLI 会话")
        try expect(resolve(.codex, "0199aaaa-0000-7000-8000-000000000009") == nil, "找不到 rollout")
    }

    t.test("其余来源不读文件、没有直达链接") {
        let resolve = try resolver()
        try expect(SessionAppLinkResolver.canResolve(.claude))
        try expect(SessionAppLinkResolver.canResolve(.codex))
        try expect(!SessionAppLinkResolver.canResolve(.cursor))
        try expect(resolve(.opencode, "11111111-1111-4111-8111-111111111111") == nil)
    }
}
