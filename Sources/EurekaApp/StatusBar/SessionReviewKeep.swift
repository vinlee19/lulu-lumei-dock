import AppKit
import EurekaIngest
import EurekaKit
import SwiftUI

/// "My choices on AI proposals": one row per decision point — what the AI offered, what I did
/// with it, and why (or plainly that no reason was stated)
struct ReviewChoicesList: View {
    let choices: [SummaryDocument.Choice]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                row(choice)
                    .padding(.vertical, 11)
                if index < choices.count - 1 {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
            }
        }
    }

    private func row(_ choice: SummaryDocument.Choice) -> some View {
        HStack(alignment: .top, spacing: 12) {
            verdictBadge(choice.verdict)
            VStack(alignment: .leading, spacing: 6) {
                line(L10n.text("AI proposed", zhHans: "AI 提议"), choice.proposal, color: .secondary)
                line(L10n.text("I chose", zhHans: "我的选择"), decisionText(choice), color: .primary, weight: .semibold)
                if let reason = choice.reason {
                    line(L10n.text("Why", zhHans: "为什么"), reason, color: .secondary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        label(L10n.text("Why", zhHans: "为什么"))
                        Text(L10n.text("Not stated in the conversation", zhHans: "对话里没有说明原因"))
                            .font(Theme.font.themed(11.5).italic())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// The badge already says accepted / rejected / changed, so a leading verdict word is dropped;
    /// a decision that is only that word reads as the localized verdict
    private func decisionText(_ choice: SummaryDocument.Choice) -> String {
        let rest = SummaryDocument.droppingVerdictWord(choice.decision)
        if !rest.isEmpty { return rest }
        switch choice.verdict {
        case .accepted: return L10n.text("Accepted as proposed", zhHans: "照单采纳")
        case .rejected: return L10n.text("Rejected", zhHans: "否决")
        case .modified: return L10n.text("Changed before using it", zhHans: "改过再用")
        case .other: return choice.decision
        }
    }

    private func line(_ title: String, _ text: String, color: Color, weight: Font.Weight = .regular) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            label(title)
            ReviewInlineText(text: text, size: 12, weight: weight, color: color)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.font.themed(10, .medium))
            .foregroundStyle(.tertiary)
            .frame(width: 76, alignment: .leading)
    }

    private func verdictBadge(_ verdict: SummaryDocument.Choice.Verdict) -> some View {
        let (icon, tint, help): (String, Color, String) = {
            switch verdict {
            case .accepted: return ("checkmark", Theme.enabledGreen, L10n.text("Accepted", zhHans: "采纳"))
            case .rejected: return ("xmark", Theme.failureRed, L10n.text("Rejected", zhHans: "否决"))
            case .modified: return ("arrow.triangle.2.circlepath", Theme.goldFg, L10n.text("Changed", zhHans: "改了再用"))
            case .other: return ("circle", Theme.brandFg, L10n.text("Decided", zhHans: "已决定"))
            }
        }()
        return Image(systemName: icon)
            .font(Theme.font.themed(10, .bold))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .background(Circle().fill(tint.opacity(0.13)))
            .help(help)
    }
}

/// "Worth keeping": the AI proposes, the person decides — each candidate is edited, saved into the
/// project's Claude memory library, or dismissed, one by one, right here
struct ReviewKeepPanel: View {
    @ObservedObject var summaries: SessionSummaryService
    let run: SummaryRunRecord
    let session: AgentSessionInfo
    let candidates: [SummaryDocument.Candidate]

    private var decisions: [String: SummaryCandidateDecision] {
        summaries.completed[run.sessionKey]?.id == run.id
            ? summaries.completed[run.sessionKey]?.candidateDecisions ?? run.candidateDecisions
            : run.candidateDecisions
    }

    private var destination: String {
        guard let cwd = session.cwd else {
            return L10n.text(
                "This session has no project directory: items can be copied but not saved.",
                zhHans: "这个会话没有项目目录：可以复制，但不能存入记忆库。")
        }
        return L10n.format(
            "Saved into %@'s Claude memory library — Claude reads it the next time you work in this project.",
            zhHans: "存入「%@」的 Claude 记忆库，下次在这个项目里协作时 Claude 会读到。",
            URL(fileURLWithPath: cwd).lastPathComponent)
    }

    var body: some View {
        let pending = candidates.filter { decisions[$0.id] == nil }.count
        ReviewCard(
            title: ReviewSectionKind.title(for: SummaryTemplateSpec.Heading.keep),
            icon: ReviewSectionKind.keep.icon,
            count: candidates.count
        ) {
            if pending > 0 {
                Text(L10n.format("%@ to review", zhHans: "%@ 条待确认", String(pending)))
                    .font(Theme.font.themed(10.5, .medium))
                    .foregroundStyle(Theme.brandFg)
            } else if !candidates.isEmpty {
                Label(L10n.text("All reviewed", zhHans: "已全部处理"), systemImage: "checkmark.circle.fill")
                    .font(Theme.font.themed(10.5, .medium))
                    .foregroundStyle(Theme.enabledGreen)
            }
        } content: {
            Text(destination)
                .font(Theme.font.themed(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if candidates.isEmpty {
                Text(L10n.text("Nothing in this session stood out as worth saving.", zhHans: "这次对话里没有特别值得沉淀的内容。"))
                    .font(Theme.font.themed(11.5))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 10) {
                    ForEach(candidates) { candidate in
                        ReviewCandidateRow(
                            summaries: summaries, run: run, session: session, candidate: candidate,
                            decision: decisions[candidate.id])
                    }
                }
            }
        }
    }
}

/// One candidate: kind, title and content (editable before saving), then save / dismiss.
/// Saved items show where they went; dismissed ones fold to a single line that can be undone.
private struct ReviewCandidateRow: View {
    @ObservedObject var summaries: SessionSummaryService
    let run: SummaryRunRecord
    let session: AgentSessionInfo
    let candidate: SummaryDocument.Candidate
    let decision: SummaryCandidateDecision?

    @State private var editing = false
    @State private var title = ""
    @State private var content = ""
    @State private var error: String?

    private var kindLabel: String {
        candidate.kind == .rule
            ? L10n.text("Rule for the AI", zhHans: "协作规则")
            : L10n.text("Project memory", zhHans: "项目记忆")
    }

    var body: some View {
        switch decision?.status {
        case .dismissed: dismissedRow
        case .saved: savedRow
        case nil: pendingRow
        }
    }

    private var pendingRow: some View {
        let hard = ThemeStyle.current.isHardEdged
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                kindTag
                if editing {
                    TextField(L10n.text("Title", zhHans: "标题"), text: $title)
                        .textFieldStyle(.plain)
                        .font(Theme.font.themed(12.5, .semibold))
                } else {
                    Text(candidate.title)
                        .font(Theme.font.themed(12.5, .semibold))
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
            }
            if editing {
                TextEditor(text: $content)
                    .font(Theme.font.themed(12))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 64, maxHeight: 140)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: hard ? 0 : 6).fill(Theme.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: hard ? 0 : 6)
                            .strokeBorder(hard ? Theme.ink : Theme.hairline, lineWidth: 1))
            } else {
                ReviewInlineText(text: candidate.content, size: 12, color: .secondary)
            }
            if let error {
                Text(error)
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(Theme.failureRed)
            }
            HStack(spacing: 8) {
                if session.cwd != nil {
                    PrimaryButton(
                        title: candidate.kind == .rule
                            ? L10n.text("Save as rule", zhHans: "存为规则")
                            : L10n.text("Save to memory", zhHans: "存入记忆"),
                        icon: "tray.and.arrow.down"
                    ) { save() }
                }
                SecondaryButton(
                    title: editing ? L10n.text("Done", zhHans: "完成") : L10n.text("Edit", zhHans: "编辑"),
                    icon: editing ? "checkmark" : "pencil"
                ) {
                    if !editing {
                        title = candidate.title
                        content = candidate.content
                    }
                    editing.toggle()
                }
                SecondaryButton(title: L10n.text("Copy", zhHans: "复制"), icon: "doc.on.doc") {
                    summaries.copy(editing ? content : candidate.content)
                }
                Spacer(minLength: 0)
                Button(L10n.text("Dismiss", zhHans: "忽略")) {
                    summaries.dismissCandidate(candidate, run: run)
                }
                .buttonStyle(.plain)
                .font(Theme.font.themed(11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .fill(Theme.brandFill(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .strokeBorder(hard ? Theme.cardBorder : Theme.brand.opacity(0.18), lineWidth: hard ? 1.5 : 1))
    }

    private var savedRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.enabledGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .font(Theme.font.themed(12, .semibold))
                if let path = decision?.path {
                    Text(L10n.format("Saved as %@", zhHans: "已存为 %@", URL(fileURLWithPath: path).lastPathComponent))
                        .font(Theme.font.themedMono(10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            if let path = decision?.path {
                SecondaryButton(title: L10n.text("Show in Finder", zhHans: "在 Finder 中显示"), icon: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .fill(Theme.enabledGreen.opacity(0.08)))
    }

    private var dismissedRow: some View {
        HStack(spacing: 8) {
            Text(candidate.title)
                .font(Theme.font.themed(11.5))
                .strikethrough()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 6)
            Button(L10n.text("Undo", zhHans: "撤销")) {
                summaries.restoreCandidate(candidate, run: run)
            }
            .buttonStyle(.plain)
            .font(Theme.font.themed(11, .medium))
            .foregroundStyle(Theme.brandFg)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var kindTag: some View {
        let tint = candidate.kind == .rule ? Theme.goldFg : Theme.brandFg
        return Text(kindLabel)
            .font(Theme.font.themed(9.5, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private func save() {
        let finalTitle = editing ? title : candidate.title
        let finalContent = editing ? content : candidate.content
        switch summaries.saveCandidate(candidate, title: finalTitle, content: finalContent, run: run, session: session) {
        case .success:
            error = nil
            editing = false
        case .failure(let failure):
            error = failure.message
        }
    }
}
