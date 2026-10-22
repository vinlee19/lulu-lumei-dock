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
            language: L10n.current.rawValue, fingerprint: "preview", coverage: coverage,
            startedAt: now.addingTimeInterval(-3600), updatedAt: now.addingTimeInterval(-3400),
            finishedAt: now.addingTimeInterval(-3400), markdown: sampleMarkdown(lastId: last))

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
        let cite = min(lastId, 3)
        return """
        ## Overview
        Preview content in the shape of template v\(SummaryTemplate.version). **User requirement:** make the loader resumable after a crash [#0].

        ## Requirements and approach changes
        - **AI proposal:** checkpoint every batch [#\(cite)]. Replaced by a single watermark row after the user asked for fewer writes.

        ## Key decisions and evidence
        | Decision | Evidence |
        | --- | --- |
        | Watermark in SQLite | **Performed action:** migration added [#\(cite)] |

        ## Completed work and verification
        - **Performed action:** `swift test` passed after the fix [#\(cite)]
        - **Unverified claim:** "no regression on large files"

        ## Unresolved items
        - Retention of old checkpoints

        ## Handoff
        ### Files
        - `Sources/Loader/Watermark.swift`
        ### Commands
        - `swift test`
        ### Next steps
        1. Add a crash-recovery test
        """
    }
}
