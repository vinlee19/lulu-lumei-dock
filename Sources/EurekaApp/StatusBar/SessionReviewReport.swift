import EurekaIngest
import EurekaKit
import SwiftUI

/// A saved summary laid out as a review: the TL;DR as the hero, then the person's learnings and
/// design calls side by side, their choices on the AI's proposals, how the approach evolved next
/// to what is still open, and the items worth keeping. Sections the page doesn't know (custom
/// templates) follow as plain cards, in the template's order. How the summary was made sits in
/// the hero's footer, out of the way.
struct SessionReviewReport: View {
    @ObservedObject var summaries: SessionSummaryService
    let run: SummaryRunRecord
    let session: AgentSessionInfo

    @State private var showDetails = false
    /// Width the report is laid out in; pairs of cards sit side by side from 680pt
    @State private var width: CGFloat = 0

    private var document: (preamble: String, sections: [SummaryDocument.Section]) {
        SummaryDocument.sections(run.markdown ?? "")
    }

    var body: some View {
        let doc = document
        let byKind = Dictionary(
            doc.sections.map { (ReviewSectionKind(heading: $0.heading), $0) },
            uniquingKeysWith: { first, _ in first })
        let generic = doc.sections.filter { ReviewSectionKind(heading: $0.heading) == .generic }

        VStack(alignment: .leading, spacing: 16) {
            hero(byKind[.tldr], preamble: doc.preamble)
            pair(card(byKind[.learned]), card(byKind[.design]))
            if let section = byKind[.choices] { choicesCard(section) }
            pair(card(byKind[.evolution], timeline: true), card(byKind[.risks]))
            ForEach(Array(generic.enumerated()), id: \.offset) { _, section in
                markdownCard(section)
            }
            if let section = byKind[.keep] {
                ReviewKeepPanel(
                    summaries: summaries, run: run, session: session,
                    candidates: SummaryDocument.candidates(section.body))
            }
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, newWidth in width = newWidth }
        })
    }

    // MARK: - Hero

    private func hero(_ tldr: SummaryDocument.Section?, preamble: String) -> some View {
        let hard = ThemeStyle.current.isHardEdged
        let lines = tldr.map { section in
            let bullets = SummaryDocument.bullets(section.body)
            return bullets.isEmpty
                ? section.body.split(whereSeparator: \.isNewline).map(String.init)
                : bullets
        } ?? (preamble.isEmpty ? [] : [preamble])
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(Theme.font.themed(10, .semibold))
                Text((run.templateName ?? SummaryTemplateSpec.handoff.name).uppercased())
                    .font(Theme.font.themed(10, .semibold))
                    .tracking(0.8)
                Spacer(minLength: 6)
                Text(relativeFormatter.localizedString(for: run.finishedAt ?? run.updatedAt, relativeTo: Date()))
                    .font(Theme.font.themed(10))
            }
            .foregroundStyle(hard ? AnyShapeStyle(Theme.onBrand) : AnyShapeStyle(Theme.brandFg))

            if lines.isEmpty {
                Text(L10n.text("This summary has no short version; the sections below have the details.",
                               zhHans: "这份总结没有速览，详情见下方各部分。"))
                    .font(Theme.font.themed(13))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        ReviewInlineText(
                            text: line,
                            size: index == 0 ? 17 : 13,
                            weight: index == 0 ? .semibold : .regular,
                            color: hard ? Theme.onBrand : (index == 0 ? .primary : .secondary),
                            linkColor: hard ? Theme.onBrand : Theme.brandFg)
                    }
                }
            }

            HStack(spacing: 8) {
                SourceBadge(source: run.executor.source, size: 12)
                Text(generatedBy)
                    .font(Theme.font.themed(10.5))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button {
                    showDetails.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(Theme.font.themed(11))
                }
                .buttonStyle(.plain)
                .help(L10n.text("How this summary was made", zhHans: "这份总结是怎么生成的"))
                .popover(isPresented: $showDetails, arrowEdge: .bottom) { details }
            }
            .foregroundStyle(hard ? AnyShapeStyle(Theme.onBrand.opacity(0.8)) : AnyShapeStyle(.secondary))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                .fill(hard
                    ? AnyShapeStyle(Theme.brand)
                    : AnyShapeStyle(LinearGradient(
                        colors: [Theme.brandFill(0.14), Theme.gold.opacity(0.10)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                        .strokeBorder(hard ? Theme.ink : Theme.brand.opacity(0.22),
                                      lineWidth: hard ? Theme.cardBorderWidth : 1))
                .themeCardShadow())
    }

    private var generatedBy: String {
        var parts = [run.executor.displayName]
        if let model = run.model { parts.append(model) }
        parts.append(L10n.format("%@ messages", zhHans: "%@ 条消息", String(run.coverage.totalMessages)))
        return parts.joined(separator: " · ")
    }

    /// Provenance, for the curious: executor version, coverage, citations, template version
    private var details: some View {
        let coverage = run.coverage
        var rows: [(String, String)] = [
            (L10n.text("Executor", zhHans: "执行器"),
             run.executor.displayName + (run.executorVersion.map { " \($0)" } ?? "")),
        ]
        if let model = run.model { rows.append((L10n.text("Model", zhHans: "模型"), model)) }
        rows.append((L10n.text("Template", zhHans: "模板"),
                     (run.templateName ?? SummaryTemplateSpec.handoff.name) + " · v\(run.templateVersion)"))
        var covered = L10n.format("%@ messages", zhHans: "%@ 条消息", String(coverage.totalMessages))
        if let first = coverage.firstMessageId, let last = coverage.lastMessageId { covered += " · #\(first)–#\(last)" }
        rows.append((L10n.text("Covers", zhHans: "覆盖"), covered))
        if coverage.chunkCount > 1 {
            rows.append((L10n.text("Parts", zhHans: "分段"),
                         L10n.format("%@ parts merged", zhHans: "%@ 段合并", String(coverage.chunkCount))))
        }
        if coverage.compactedToolSteps > 0 {
            rows.append((L10n.text("Tool steps", zhHans: "工具步骤"),
                         L10n.format("%@ compacted", zhHans: "压缩 %@ 个", String(coverage.compactedToolSteps))))
        }
        rows.append((L10n.text("Citations", zhHans: "引用"),
                     L10n.format("%@ kept, %@ dropped", zhHans: "保留 %@ 处，丢弃 %@ 处",
                                 String(coverage.validReferences), String(coverage.droppedReferences))))
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.0)
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                    Text(row.1)
                        .font(Theme.font.themedMono(10.5))
                        .textSelection(.enabled)
                }
            }
            Text(L10n.text("Click a #n citation to open that message in the conversation.",
                           zhHans: "点击 #n 引用可以跳到对话里的原消息。"))
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    // MARK: - Sections

    /// Two cards side by side when there is room, stacked otherwise; empty ones are left out
    @ViewBuilder
    private func pair<A: View, B: View>(_ left: A?, _ right: B?) -> some View {
        switch (left, right) {
        case let (left?, right?):
            if width >= 680 {
                // Equal columns that stretch to the taller card, so the pair reads as one row
                HStack(alignment: .top, spacing: 16) {
                    left.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    right.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 16) {
                    left
                    right
                }
            }
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): EmptyView()
        }
    }

    /// A list section as a card, nil when the section is missing or says "None"
    private func card(_ section: SummaryDocument.Section?, timeline: Bool = false) -> AnyView? {
        guard let section, !SummaryDocument.isEmptySection(section.body) else { return nil }
        let kind = ReviewSectionKind(heading: section.heading)
        let items = SummaryDocument.bullets(section.body)
        let tint = kind == .risks ? Theme.goldFg : Theme.brandFg
        return AnyView(ReviewCard(
            title: ReviewSectionKind.title(for: section.heading), icon: kind.icon, tint: tint,
            count: items.isEmpty ? nil : items.count
        ) {
            if items.isEmpty {
                MarkdownRichText(text: SummaryReferences.linkify(section.body, scheme: summaryMessageScheme))
            } else if timeline {
                ReviewTimeline(steps: items)
            } else {
                ReviewBulletList(items: items, marker: tint)
            }
        })
    }

    @ViewBuilder
    private func choicesCard(_ section: SummaryDocument.Section) -> some View {
        if !SummaryDocument.isEmptySection(section.body) {
            let choices = SummaryDocument.choices(section.body)
            ReviewCard(
                title: ReviewSectionKind.title(for: section.heading), icon: ReviewSectionKind.choices.icon,
                count: choices.isEmpty ? nil : choices.count
            ) {
                if choices.isEmpty {
                    MarkdownRichText(text: SummaryReferences.linkify(section.body, scheme: summaryMessageScheme))
                } else {
                    ReviewChoicesList(choices: choices)
                }
            }
        }
    }

    @ViewBuilder
    private func markdownCard(_ section: SummaryDocument.Section) -> some View {
        if !SummaryDocument.isEmptySection(section.body) {
            ReviewCard(title: ReviewSectionKind.title(for: section.heading), icon: ReviewSectionKind.generic.icon) {
                MarkdownRichText(text: SummaryReferences.linkify(section.body, scheme: summaryMessageScheme))
            }
        }
    }
}
