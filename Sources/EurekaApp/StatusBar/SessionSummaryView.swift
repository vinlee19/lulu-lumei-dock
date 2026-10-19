import EurekaIngest
import EurekaKit
import EurekaSummary
import SwiftUI

/// URL scheme of source-message citations inside a rendered summary (`[#12]` → message 12)
let summaryMessageScheme = "eureka-message"

/// AI Summary tab of the session detail pane: live progress, the saved summary with its
/// provenance, failures with recovery actions, and the executor choice.
struct SessionSummaryPane: View {
    @ObservedObject var summaries: SessionSummaryService
    let session: AgentSessionInfo
    /// Jump to a cited message in the Conversation tab
    let onJump: (Int) -> Void

    @State private var note: String?
    @State private var showDraft = false
    @State private var showExecutors = false

    private var key: String { summaries.key(session) }
    private var live: SummaryLiveState? { summaries.live[key] }
    private var saved: SummaryRunRecord? { summaries.completed[key] }

    /// The newest finished run when it is a failure newer than the saved summary
    private var failure: SummaryRunRecord? {
        guard let last = summaries.lastFinished[key], last.status != .completed else { return nil }
        if let saved, (saved.finishedAt ?? .distantPast) >= (last.finishedAt ?? .distantPast) {
            return nil
        }
        return last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            if let reason = SummarySourceSupport.unsupportedReason(session.source) {
                EmptyStateView(
                    icon: "lock.doc",
                    title: L10n.text("This session can't be summarized", zhHans: "这个会话无法总结"),
                    hint: reason)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let live { progressCard(live) }
                        if live == nil, let failure { failureCard(failure) }
                        if let saved {
                            savedSummary(saved)
                            DisclosureGroup(
                                L10n.text("Executors and models", zhHans: "执行器与模型"),
                                isExpanded: $showExecutors
                            ) {
                                executorList.padding(.top, 6)
                            }
                            .font(Theme.font.themed(11, .medium))
                        } else if live == nil && failure == nil {
                            emptyState
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        // The summary is model output built from transcript text, so a prompt-injected session can
        // plant links in it. Only our citation links act in-app and only plain web links reach
        // the system; file:, app-specific and every other scheme is dropped.
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == summaryMessageScheme {
                guard let id = Int(url.host ?? "") else { return .discarded }
                onJump(id)
                return .handled
            }
            let scheme = url.scheme?.lowercased()
            return scheme == "https" || scheme == "http" ? .systemAction : .discarded
        })
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            PaneHeader(icon: "sparkles", title: L10n.text("AI Summary", zhHans: "AI 总结")) {
                if let live {
                    CountChip(live.stage.label)
                } else if saved != nil, case .stale = summaries.freshness[key] {
                    CountChip(L10n.text("Outdated", zhHans: "已过期"))
                }
            }
            if let note {
                Text(note)
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if live != nil {
                SecondaryButton(
                    title: L10n.text("Cancel", zhHans: "取消"), icon: "stop.fill", destructive: true,
                    help: L10n.text("Stop the CLI and keep the partial output as a draft", zhHans: "停止 CLI，已有输出保留为草稿")
                ) {
                    summaries.cancel(session)
                }
            } else if let saved {
                SecondaryButton(
                    title: L10n.text("Copy", zhHans: "复制"), icon: "doc.on.doc",
                    help: L10n.text("Copy the summary as Markdown", zhHans: "复制总结 Markdown")
                ) {
                    summaries.copy(summaries.exportDocument(saved, session: session))
                    flash(L10n.text("Copied", zhHans: "已复制"))
                }
                SecondaryButton(
                    title: L10n.text("Export", zhHans: "导出"), icon: "square.and.arrow.up",
                    help: L10n.text("Save the summary as a .md file", zhHans: "把总结存为 .md 文件")
                ) {
                    if let url = summaries.export(saved, session: session) {
                        flash(L10n.format("Exported %@", zhHans: "已导出 %@", url.lastPathComponent))
                    }
                }
            }
        }
    }

    private func flash(_ text: String) {
        note = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { note = nil }
    }

    // MARK: - Progress

    private func progressCard(_ live: SummaryLiveState) -> some View {
        SectionCard {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(live.stage.label)
                    .font(Theme.font.themed(12.5, .semibold))
                if live.chunkTotal > 1 {
                    CountChip(live.stage == .merging
                        ? L10n.format("%@ parts done · merging", zhHans: "%@ 段完成 · 合并中", String(live.chunkTotal))
                        : L10n.format("Part %@ of %@", zhHans: "第 %@ / %@ 段", String(min(live.chunksDone + 1, live.chunkTotal)), String(live.chunkTotal)))
                }
                Spacer(minLength: 0)
                SourceBadge(source: live.executor.source, size: 12)
                Text(live.executor.displayName)
                    .font(Theme.font.themed(11))
                    .foregroundStyle(.secondary)
            }
            // Elapsed / last event tick every second without touching the service
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 14) {
                    metric(L10n.text("Elapsed", zhHans: "已用时"), formatDuration(context.date.timeIntervalSince(live.startedAt)))
                    metric(
                        L10n.text("Last event", zhHans: "最近事件"),
                        live.lastEventAt.map {
                            L10n.format("%@ ago", zhHans: "%@ 前", formatDuration(max(0, context.date.timeIntervalSince($0))))
                        } ?? L10n.text("none yet", zhHans: "尚无"))
                    if let coverage = live.coverage {
                        metric(L10n.text("Input", zhHans: "输入"), L10n.format(
                            "%@ messages · ~%@ tokens", zhHans: "%@ 条消息 · 约 %@ tokens",
                            String(coverage.totalMessages), formatTokens(coverage.estimatedTokens)))
                    }
                }
            }
            if !live.streamedText.isEmpty {
                Divider()
                MarkdownRichText(text: SummaryReferences.linkify(live.streamedText, scheme: summaryMessageScheme))
            } else if !live.streams && (live.stage == .waiting || live.stage == .summarizing) {
                Text(L10n.format(
                    "%@ returns the text when it finishes; there is no partial output to show.",
                    zhHans: "%@ 完成后才返回全文，过程中没有可显示的部分输出。", live.executor.displayName))
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(.secondary)
            }
            if saved != nil {
                Text(L10n.text("The previous summary below stays until this run succeeds.", zhHans: "下方的上一版总结会保留，直到这次生成成功。"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(Theme.font.themed(9.5, .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(Theme.font.themedMono(11, .medium))
                .lineLimit(1)
        }
    }

    // MARK: - Failure

    private func failureCard(_ run: SummaryRunRecord) -> some View {
        SectionCard {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: run.status == .failed ? "exclamationmark.triangle.fill" : "pause.circle")
                    .font(Theme.font.themed(13))
                    .foregroundStyle(run.status == .failed ? Theme.goldFg : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text((run.errorKind ?? .executorError).label)
                        .font(Theme.font.themed(12.5, .semibold))
                    if let message = run.errorMessage, !message.isEmpty {
                        Text(message)
                            .font(Theme.font.themedMono(10.5))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text((run.errorKind ?? .executorError).recoveryHint)
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(.secondary)
                    Text(L10n.format(
                        "%@ · %@", zhHans: "%@ · %@", run.executor.displayName,
                        relativeFormatter.localizedString(for: run.finishedAt ?? run.updatedAt, relativeTo: Date())))
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                PrimaryButton(
                    title: L10n.format("Retry with %@", zhHans: "用 %@ 重试", run.executor.displayName),
                    icon: "arrow.clockwise"
                ) {
                    summaries.summarize(session, with: run.executor)
                }
                .disabled(summaries.availability[run.executor]?.isAvailable != true)
                MenuButton(title: L10n.text("Use another CLI", zhHans: "换一个 CLI"), icon: "arrow.triangle.branch") {
                    SummaryExecutorMenuItems(summaries: summaries, session: session)
                }
                if let draft = run.draft {
                    SecondaryButton(
                        title: showDraft ? L10n.text("Hide draft", zhHans: "收起草稿") : L10n.text("Show draft", zhHans: "查看草稿"),
                        icon: "doc.text.magnifyingglass"
                    ) {
                        showDraft.toggle()
                    }
                    SecondaryButton(title: L10n.text("Copy draft", zhHans: "复制草稿"), icon: "doc.on.doc") {
                        summaries.copy(draft)
                        flash(L10n.text("Copied", zhHans: "已复制"))
                    }
                }
                Spacer(minLength: 0)
            }
            if showDraft, let draft = run.draft {
                Divider()
                Text(L10n.text("Partial output — incomplete and not saved as the summary", zhHans: "部分输出——不完整，未作为总结保存"))
                    .font(Theme.font.themed(10, .medium))
                    .foregroundStyle(Theme.goldFg)
                MarkdownRichText(text: draft)
            }
        }
    }

    // MARK: - Saved summary

    @ViewBuilder
    private func savedSummary(_ run: SummaryRunRecord) -> some View {
        if case .stale(let newMessages) = summaries.freshness[key] {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Theme.goldFg)
                Text(newMessages > 0
                    ? L10n.format(
                        "The conversation has %@ new messages since this summary.",
                        zhHans: "这份总结之后对话新增了 %@ 条消息。", String(newMessages))
                    : L10n.text("The conversation changed since this summary.", zhHans: "这份总结之后对话内容有变化。"))
                    .font(Theme.font.themed(11))
                Spacer(minLength: 4)
                if live == nil {
                    SecondaryButton(
                        title: L10n.text("Regenerate", zhHans: "重新生成"), icon: "arrow.clockwise"
                    ) {
                        summaries.summarize(session, with: summaries.preferredExecutor ?? run.executor)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                    .fill(Theme.goldFg.opacity(0.1)))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
        }
        VStack(alignment: .leading, spacing: 12) {
            provenance(run)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            MarkdownRichText(text: SummaryReferences.linkify(run.markdown ?? "", scheme: summaryMessageScheme))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.card)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.card)
                        .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
                .themeCardShadow())
    }

    /// Who wrote it, from what, and when
    private func provenance(_ run: SummaryRunRecord) -> some View {
        let coverage = run.coverage
        var parts = [L10n.format("%@ messages", zhHans: "%@ 条消息", String(coverage.totalMessages))]
        if let first = coverage.firstMessageId, let last = coverage.lastMessageId {
            parts.append("#\(first)–#\(last)")
        }
        if coverage.chunkCount > 1 {
            parts.append(L10n.format("%@ parts merged", zhHans: "%@ 段合并", String(coverage.chunkCount)))
        }
        if coverage.compactedToolSteps > 0 {
            parts.append(L10n.format("%@ tool steps compacted", zhHans: "%@ 个工具步骤已压缩", String(coverage.compactedToolSteps)))
        }
        if coverage.excludedThinking > 0 {
            parts.append(L10n.format("%@ thinking blocks excluded", zhHans: "排除 %@ 段思考", String(coverage.excludedThinking)))
        }
        if coverage.validReferences > 0 {
            parts.append(L10n.format("%@ citations", zhHans: "%@ 处引用", String(coverage.validReferences)))
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SourceBadge(source: run.executor.source, size: 12)
                Text(run.executor.displayName + (run.executorVersion.map { " \($0)" } ?? ""))
                    .font(Theme.font.themed(11, .semibold))
                if let model = run.model {
                    Text(model)
                        .font(Theme.font.themedMono(10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(relativeFormatter.localizedString(for: run.finishedAt ?? run.updatedAt, relativeTo: Date()))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
            }
            Text(L10n.format("Covers %@", zhHans: "覆盖 %@", parts.joined(separator: " · ")))
                .font(Theme.font.themed(10))
                .foregroundStyle(.secondary)
            if coverage.validReferences > 0 {
                Text(L10n.text("Click a [#n] citation to open that message in the conversation.", zhHans: "点击 [#n] 引用可跳到对话中的原消息。"))
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            EmptyStateView(
                icon: "sparkles",
                title: L10n.text("No AI summary yet", zhHans: "还没有 AI 总结"),
                hint: L10n.text(
                    "A local CLI reads the whole conversation and writes an overview, the decisions and their evidence, what was done and verified, what is open, and a handoff. It uses that CLI's own sign-in and model, so it is not offline.",
                    zhHans: "由本地 CLI 读取完整对话，写出概览、关键决策与依据、已完成与验证、未决事项和交接信息。使用该 CLI 自己的登录和模型，并非离线推理。"))
                .padding(.top, 24)
            SectionCard(L10n.text("Executors", zhHans: "执行器")) { executorList }
        }
    }

    @ViewBuilder
    private var executorList: some View {
        ForEach(SummaryExecutorKind.allCases) { kind in
            executorRow(kind)
        }
    }

    private func executorRow(_ kind: SummaryExecutorKind) -> some View {
        let availability = summaries.availability[kind]
        return HStack(spacing: 8) {
            SourceBadge(source: kind.source, size: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName + (availability?.executor?.version.map { " \($0)" } ?? ""))
                    .font(Theme.font.themed(11.5, .medium))
                Text(availability.map { $0.isAvailable
                    ? ($0.executor?.path ?? "")
                    : ($0.reason ?? "") } ?? L10n.text("Checking…", zhHans: "检测中…"))
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            TextField(
                L10n.text("Model (optional)", zhHans: "模型（可选）"),
                text: Binding(
                    get: { summaries.models[kind] ?? "" },
                    set: { summaries.models[kind] = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(Theme.font.themedMono(10.5))
                .frame(width: 150)
                .help(L10n.text("Passed to the CLI as --model; leave empty for its default", zhHans: "作为 --model 传给 CLI；留空则用它的默认模型"))
            SecondaryButton(title: L10n.text("Summarize", zhHans: "总结"), icon: "sparkles") {
                summaries.summarize(session, with: kind)
            }
            .disabled(availability?.isAvailable != true)
        }
    }
}
