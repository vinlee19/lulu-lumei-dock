import EurekaIngest
import EurekaKit
import EurekaSummary
import SwiftUI

extension PreviewRenderer {
    /// AI Summary tab states for `--render-pages`: saved summary (with a stale banner), a live
    /// chunked run over the previous summary, and a failure with a draft. The summary service is a
    /// private, seeded instance on its own defaults suite: no CLI runs and no preference changes.
    static func renderSummaryPages(
        sessions: SessionBrowserService, settings: AppSettings, skillMemory: SkillMemoryService,
        plans: PlansService,
        snap: (_ name: String, _ view: AnyView, _ dark: Bool, _ width: CGFloat, _ height: CGFloat) -> Void
    ) {
        guard let session = sessions.selected,
              SummarySourceSupport.unsupportedReason(session.source) == nil,
              let defaults = UserDefaults(suiteName: "com.vinlee.eureka.summary-preview")
        else { return }
        let key = AgentTask.key(source: session.source, sessionId: session.id)
        let now = Date()
        let last = max(0, sessions.transcript.count - 1)
        let availability = [
            SummaryExecutorAvailability(
                kind: .claude,
                executor: ResolvedExecutor(kind: .claude, path: "/usr/local/bin/claude", version: "2.1.303", environment: [:]),
                reason: nil),
            SummaryExecutorAvailability(
                kind: .codex,
                executor: ResolvedExecutor(kind: .codex, path: "/opt/homebrew/bin/codex", version: "0.162.1", environment: [:]),
                reason: nil),
            SummaryExecutorAvailability(
                kind: .opencode, executor: nil,
                reason: L10n.format("`%@` was not found on your login shell PATH.", zhHans: "在登录 shell 的 PATH 中找不到 `%@`。", "opencode")),
        ]
        let coverage = SummaryCoverage(
            totalMessages: sessions.transcript.count, userMessages: 6, firstMessageId: 0,
            lastMessageId: last, compactedToolSteps: 41, excludedThinking: 0, chunkCount: 3,
            splitMessages: 0, estimatedTokens: 96_400, validReferences: 4, droppedReferences: 0)
        let saved = SummaryRunRecord(
            id: "preview-done", source: session.source, sessionId: session.id, status: .completed,
            executor: .claude, executorVersion: "2.1.303", model: "claude-opus-5-5",
            templateId: SummaryTemplateSpec.defaultId, templateName: SummaryTemplateSpec.collabReview.name,
            language: L10n.current.rawValue, fingerprint: "preview", coverage: coverage,
            startedAt: now.addingTimeInterval(-3600), updatedAt: now.addingTimeInterval(-3400),
            finishedAt: now.addingTimeInterval(-3400), markdown: sampleMarkdown(lastId: last),
            candidateDecisions: [
                "memory:" + (L10n.current == .simplifiedChinese ? "恢复时重放最后一批" : "Recovery replays the last batch").lowercased():
                    SummaryCandidateDecision(status: .saved, path: "/tmp/project_recovery_replays_the_last_batch.md", decidedAt: now),
            ])

        func page(_ service: SessionSummaryService) -> AnyView {
            AnyView(SessionsView(
                service: sessions, settings: settings, skillMemory: skillMemory, plans: plans,
                summaries: service, initialDetailTab: .summary))
        }

        let done = SessionSummaryService(defaults: defaults)
        done.seedForPreview(
            availability: availability, completed: [saved],
            freshness: [key: .stale(newMessages: 3)], preferred: .claude)
        snap("pages-session-summary", page(done), false, 1270, 980)
        // The whole review, top to bottom (the page view stops at the window height)
        let report = AnyView(
            ScrollView {
                SessionReviewReport(summaries: done, run: saved, session: session)
                    .padding(20)
            }
            .background(Theme.surfaceSecondary))
        snap("pages-session-review-full", report, false, 900, 2400)
        snap("pages-session-review-full-dark", report, true, 900, 2400)
        snap("pages-session-summary-dark", page(done), true, 1270, 980)
        snap("pages-session-summary-min", page(done), false, 675, 512)

        let running = SessionSummaryService(defaults: defaults)
        running.seedForPreview(
            availability: availability,
            live: [SummaryLiveState(
                runId: "preview-live", sessionKey: key, executor: .claude, stage: .summarizing,
                startedAt: now.addingTimeInterval(-74), lastEventAt: now.addingTimeInterval(-1),
                chunksDone: 1, chunkTotal: 3,
                streamedText: "## Overview\nThe user asked to make the incremental loader resumable [#0]; the assistant",
                streams: true, coverage: coverage)],
            completed: [saved], preferred: .claude)
        snap("pages-session-summary-live", page(running), false, 1270, 980)

        let failed = SessionSummaryService(defaults: defaults)
        failed.seedForPreview(
            availability: availability,
            lastFinished: [SummaryRunRecord(
                id: "preview-failed", source: session.source, sessionId: session.id,
                status: .failed, executor: .codex, executorVersion: "0.162.1",
                language: L10n.current.rawValue, startedAt: now.addingTimeInterval(-300),
                updatedAt: now.addingTimeInterval(-240), finishedAt: now.addingTimeInterval(-240),
                markdown: "## Overview\nPartial notes…", errorKind: .authentication,
                errorMessage: "401 Unauthorized: sign in again")],
            preferred: .codex)
        snap("pages-session-summary-failed", page(failed), false, 1270, 980)

        let empty = SessionSummaryService(defaults: defaults)
        empty.seedForPreview(availability: availability, preferred: nil)
        snap("pages-session-summary-empty", page(empty), false, 1270, 980)

        // Popover contents can't be captured offscreen as popovers; render them on their own
        let pickers = SessionSummaryService(defaults: defaults)
        pickers.seedForPreview(
            availability: availability, preferred: .claude,
            modelOptions: [.codex: [
                SummaryModelOption(value: "gpt-6.1-sol", label: "GPT-6.1-Sol", isDefault: true),
                SummaryModelOption(value: "gpt-6-astra", label: "GPT-6-Astra"),
                SummaryModelOption(value: "gpt-5.6-terra", label: "GPT-5.6-Terra"),
            ]])
        let popovers = AnyView(
            HStack(alignment: .top, spacing: 24) {
                SummaryExecutorPicker(summaries: pickers) { _ in }
                SummaryModelList(summaries: pickers, kind: .codex)
            }
            .padding(20))
        snap("pages-session-summary-pickers", popovers, false, 680, 360)
        snap("pages-session-summary-pickers-dark", popovers, true, 680, 360)
        defaults.removePersistentDomain(forName: "com.vinlee.eureka.summary-preview")
    }

    /// Placeholder content in the template's shape (not generated from the session)
    private static func sampleMarkdown(lastId: Int) -> String {
        let a = min(lastId, 3), b = min(lastId, 12), c = min(lastId, 40)
        if L10n.current == .simplifiedChinese {
            return """
            ## TL;DR
            - 增量加载器可以在崩溃后断点续跑了，改用单行水位记录进度 [#\(b)]。
            - 测试已通过，大文件场景还没有实测。
            - 下一步：补一个崩溃恢复测试。

            ## What I learned
            - SQLite 的 WAL 模式下，读连接不会阻塞写入，所以水位可以和数据在同一个库里更新 [#\(a)]。
            - 每批都写检查点会把写放大放到 10 倍以上，这是之前卡顿的真正原因 [#\(b)]。

            ## My design decisions
            - 进度只记一行水位，不做逐批检查点：写入少、恢复逻辑简单 [#\(b)]。
            - 恢复时重放最后一批，接受少量重复处理，换取实现简单（原因未说明）。

            ## My choices on AI proposals
            - **AI proposed:** 每批写一个检查点 [#\(a)] → **I chose:** rejected, 改成单行水位 — **Why:** 写入次数太多，用户希望更少的写 [#\(b)]
            - **AI proposed:** 用 Redis 记录进度 → **I chose:** rejected — **Why:** 不想为这个引入新依赖 [#\(b)]
            - **AI proposed:** 恢复时跳过最后一批 → **I chose:** modified, 改为重放最后一批 — **Why:** reason not stated
            - **AI proposed:** 加一条迁移脚本 [#\(c)] → **I chose:** accepted — **Why:** reason not stated

            ## How the approach evolved
            - [#\(a)] 一开始打算每批写检查点。
            - [#\(b)] 发现写放大严重，改为单行水位。
            - [#\(c)] 最终方案：水位与数据同库，恢复时重放最后一批。

            ## Open questions and risks
            - 旧检查点文件的清理策略还没定。
            - AI 说“大文件不会退化”，对话里没有验证。

            ## Worth keeping
            - **Memory** | 增量加载用单行水位 | 增量加载器的进度只记一行水位、与数据同库更新；不要改回逐批检查点，写放大会超过 10 倍 [#\(b)]
            - **Rule** | 先说写入代价再给方案 | 提出持久化方案时，先说明每次操作的写入次数和放大倍数，再给实现 [#\(b)]
            - **Memory** | 恢复时重放最后一批 | 崩溃恢复会重放最后一批，下游需要能容忍少量重复 [#\(c)]
            """
        }
        return """
        ## TL;DR
        - The incremental loader now resumes after a crash, tracking progress in a single watermark row [#\(b)].
        - Tests pass; large files were not measured.
        - Next: add a crash-recovery test.

        ## What I learned
        - With SQLite in WAL mode readers don't block the writer, so the watermark can live beside the data [#\(a)].
        - Checkpointing every batch multiplied writes more than tenfold, the real cause of the stalls [#\(b)].

        ## My design decisions
        - Track progress in one watermark row rather than per-batch checkpoints: fewer writes, simpler recovery [#\(b)].
        - Replay the last batch on recovery, accepting a little duplicate work (reason not stated).

        ## My choices on AI proposals
        - **AI proposed:** a checkpoint per batch [#\(a)] → **I chose:** rejected, one watermark row instead — **Why:** too many writes [#\(b)]
        - **AI proposed:** keep progress in Redis → **I chose:** rejected — **Why:** no new dependency for this [#\(b)]
        - **AI proposed:** skip the last batch on recovery → **I chose:** modified, replay it instead — **Why:** reason not stated
        - **AI proposed:** add a migration script [#\(c)] → **I chose:** accepted — **Why:** reason not stated

        ## How the approach evolved
        - [#\(a)] Started with per-batch checkpoints.
        - [#\(b)] Write amplification showed up; switched to one watermark row.
        - [#\(c)] Final: watermark beside the data, replay the last batch on recovery.

        ## Open questions and risks
        - No retention policy for old checkpoint files yet.
        - "No regression on large files" was claimed, never verified.

        ## Worth keeping
        - **Memory** | One watermark row for incremental loads | The loader tracks progress in a single watermark row updated with the data; don't go back to per-batch checkpoints, they amplify writes over tenfold [#\(b)]
        - **Rule** | State the write cost before proposing persistence | When proposing a persistence scheme, state writes per operation and the amplification first [#\(b)]
        - **Memory** | Recovery replays the last batch | Crash recovery replays the last batch, so downstream must tolerate a few duplicates [#\(c)]
        """
    }
}
