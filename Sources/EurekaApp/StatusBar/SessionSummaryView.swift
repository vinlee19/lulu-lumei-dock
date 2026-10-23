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
            SummaryTemplateChip(summaries: summaries)
            if live == nil, saved != nil, case .stale = summaries.freshness[key] {
                CountChip(L10n.text("Outdated", zhHans: "已过期"))
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

    /// A run in progress: what is happening in plain words, the sections that are coming, and
    /// the live text tucked behind a disclosure for those who want to watch it
    private func progressCard(_ live: SummaryLiveState) -> some View {
        let sections = summaries.template(id: summaries.selectedTemplateId)?.usableSections ?? []
        return ReviewCard(
            title: L10n.text("Writing your review", zhHans: "正在生成复盘"), icon: "sparkles"
        ) {
            HStack(spacing: 6) {
                SourceBadge(source: live.executor.source, size: 11)
                Text(live.executor.displayName)
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(.secondary)
            }
        } content: {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stageSentence(live))
                        .font(Theme.font.themed(12.5, .medium))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(L10n.format(
                            "%@ so far", zhHans: "已用 %@",
                            formatDuration(context.date.timeIntervalSince(live.startedAt))))
                            .font(Theme.font.themed(10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if !sections.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(sections) { section in
                        HStack(spacing: 8) {
                            Image(systemName: ReviewSectionKind(heading: section.heading).icon)
                                .font(Theme.font.themed(10))
                                .foregroundStyle(Theme.brandFg.opacity(0.6))
                                .frame(width: 16)
                            Text(ReviewSectionKind.title(for: section.heading))
                                .font(Theme.font.themed(11.5))
                                .foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.hairline)
                                .frame(height: 6)
                                .frame(maxWidth: 160)
                        }
                    }
                }
                .padding(.top, 2)
            }
            if !live.streamedText.isEmpty {
                DisclosureGroup(L10n.text("Watch the live output", zhHans: "查看实时输出")) {
                    MarkdownRichText(text: SummaryReferences.linkify(live.streamedText, scheme: summaryMessageScheme))
                        .padding(.top, 6)
                }
                .font(Theme.font.themed(11, .medium))
                .tint(Theme.brandFg)
            }
            if saved != nil {
                Text(L10n.text("The previous review below stays until this one is ready.", zhHans: "下方的上一版复盘会保留，直到这次生成完成。"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func stageSentence(_ live: SummaryLiveState) -> String {
        switch live.stage {
        case .queued, .reading, .preparing:
            return L10n.text("Reading the whole conversation…", zhHans: "正在读完整段对话…")
        case .launching, .waiting:
            return L10n.format("Waiting for %@ to answer…", zhHans: "等待 %@ 回应…", live.executor.displayName)
        case .summarizing where live.chunkTotal > 1:
            return L10n.format(
                "Reading part %@ of %@ of a long conversation…", zhHans: "长对话，正在读第 %@ / %@ 段…",
                String(min(live.chunksDone + 1, live.chunkTotal)), String(live.chunkTotal))
        case .summarizing:
            return L10n.text("Writing the review…", zhHans: "正在写复盘…")
        case .merging:
            return L10n.text("Putting the parts together…", zhHans: "正在把各段合成一份…")
        default:
            return live.stage.label
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
                SummaryExecutorPickerButton(
                    summaries: summaries,
                    title: L10n.text("Use another CLI", zhHans: "换一个 CLI"),
                    icon: "arrow.triangle.branch"
                ) { kind in
                    summaries.summarize(session, with: kind)
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
        SessionReviewReport(summaries: summaries, run: run, session: session)
    }

    // MARK: - Empty state

    /// First visit: what a review gives you, the template to use, and one button to start
    private var emptyState: some View {
        let hard = ThemeStyle.current.isHardEdged
        let executor = summaries.preferredExecutor.flatMap { summaries.availability[$0]?.isAvailable == true ? $0 : nil }
            ?? SummaryExecutorKind.allCases.first { summaries.availability[$0]?.isAvailable == true }
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(Theme.font.themed(22, .semibold))
                    .foregroundStyle(hard ? Theme.ink : Theme.brandFg)
                Text(L10n.text("Turn this session into something you keep", zhHans: "把这次协作，变成你的收获"))
                    .font(Theme.font.themed(19, .bold))
                Text(L10n.text(
                    "A local CLI reads the whole conversation and writes it up from your side: what you learned, the calls you made and why, and how you chose among the AI's proposals. Worth-keeping items can be saved to the project's memory, one by one.",
                    zhHans: "由本地 CLI 读完整段对话，从你的角度写出：你学到了什么、做了哪些决定和为什么、面对 AI 的方案你是怎么选的。值得留下的内容，可以逐条确认后存入项目记忆。"))
                    .font(Theme.font.themed(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Template", zhHans: "模板"))
                    .font(Theme.font.themed(11, .semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(summaries.templates) { template in
                        templateCard(template)
                    }
                }
            }
            HStack(spacing: 10) {
                if let executor {
                    PrimaryButton(
                        title: L10n.format("Write the review with %@", zhHans: "用 %@ 生成复盘", executor.displayName),
                        icon: "sparkles"
                    ) {
                        summaries.summarize(session, with: executor)
                    }
                    SummaryExecutorPickerButton(
                        summaries: summaries, title: L10n.text("Another CLI", zhHans: "换一个 CLI"),
                        icon: "arrow.triangle.branch"
                    ) { kind in
                        summaries.summarize(session, with: kind)
                    }
                } else {
                    Text(summaries.probing
                        ? L10n.text("Looking for local CLIs…", zhHans: "正在查找本地 CLI…")
                        : L10n.text("No local CLI can write a review yet; see below.", zhHans: "还没有可用的本地 CLI，见下方。"))
                        .font(Theme.font.themed(11.5))
                        .foregroundStyle(.secondary)
                }
            }
            DisclosureGroup(
                L10n.text("Executors and models", zhHans: "执行器与模型"), isExpanded: $showExecutors
            ) {
                VStack(alignment: .leading, spacing: 10) { executorList }
                    .padding(.top, 8)
            }
            .font(Theme.font.themed(11, .medium))
            .tint(Theme.brandFg)
        }
        .padding(.top, 18)
    }

    private func templateCard(_ template: SummaryTemplateSpec) -> some View {
        let selected = summaries.selectedTemplateId == template.id
        let hard = ThemeStyle.current.isHardEdged
        return Button {
            summaries.selectedTemplateId = template.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(Theme.font.themed(11))
                        .foregroundStyle(selected ? Theme.brandFg : .secondary)
                    Text(template.name)
                        .font(Theme.font.themed(12.5, .semibold))
                        .lineLimit(1)
                }
                Text(template.summary)
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                Text(template.usableSections.map { ReviewSectionKind.title(for: $0.heading) }.joined(separator: " · "))
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                    .fill(selected ? Theme.brandFill(0.10) : Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                    .strokeBorder(
                        selected ? (hard ? Theme.ink : Theme.brand.opacity(0.55)) : (hard ? Theme.cardBorder : Theme.hairline),
                        lineWidth: selected ? (hard ? Theme.cardBorderWidth : 1.5) : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(kind.displayName)
                        .font(Theme.font.themed(11.5, .medium))
                    if let version = availability?.executor?.version {
                        Text(version)
                            .font(Theme.font.themedMono(9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(availability.map { $0.isAvailable
                    ? ($0.executor?.path ?? "")
                    : ($0.reason ?? "") } ?? L10n.text("Checking…", zhHans: "检测中…"))
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            SummaryModelField(summaries: summaries, kind: kind)
            SecondaryButton(title: L10n.text("Summarize", zhHans: "总结"), icon: "sparkles") {
                summaries.summarize(session, with: kind)
            }
            .disabled(availability?.isAvailable != true)
        }
    }
}
