import EurekaKit
import SwiftUI

/// Building blocks of the session review page: how a section heading maps to a layout, inline
/// text with citation links, and the card chrome every block shares.

/// What a `##` section becomes on the page. Built-in headings get a purpose-made layout and a
/// localized title; anything else (custom templates) renders as a plain Markdown card.
enum ReviewSectionKind: Equatable {
    case tldr, learned, design, choices, evolution, risks, keep, generic

    init(heading: String) {
        typealias H = SummaryTemplateSpec.Heading
        switch heading.trimmingCharacters(in: .whitespaces).lowercased() {
        case H.tldr.lowercased(): self = .tldr
        case H.learned.lowercased(): self = .learned
        case H.designDecisions.lowercased(): self = .design
        case H.choices.lowercased(): self = .choices
        case H.evolution.lowercased(): self = .evolution
        case H.risks.lowercased(), "unresolved items": self = .risks
        case H.keep.lowercased(): self = .keep
        default: self = .generic
        }
    }

    var icon: String {
        switch self {
        case .tldr: return "sparkles"
        case .learned: return "lightbulb"
        case .design: return "pencil.and.ruler"
        case .choices: return "arrow.triangle.branch"
        case .evolution: return "point.topleft.down.to.point.bottomright.curvepath"
        case .risks: return "exclamationmark.triangle"
        case .keep: return "tray.and.arrow.down"
        case .generic: return "text.alignleft"
        }
    }

    /// Localized title for built-in headings; other headings are shown as written
    static func title(for heading: String) -> String {
        let kind = ReviewSectionKind(heading: heading)
        switch kind {
        case .tldr: return L10n.text("In short", zhHans: "一句话复盘")
        case .learned: return L10n.text("What I learned", zhHans: "我学到的")
        case .design: return L10n.text("My design decisions", zhHans: "我的设计决定")
        case .choices: return L10n.text("My choices on AI proposals", zhHans: "面对 AI 方案，我的抉择")
        case .evolution: return L10n.text("How the approach evolved", zhHans: "思路是怎么演变的")
        case .risks: return L10n.text("Open questions and risks", zhHans: "待解决与风险")
        case .keep: return L10n.text("Worth keeping", zhHans: "值得沉淀")
        case .generic: return handoffTitles[heading.lowercased()] ?? heading
        }
    }

    /// Titles of the handoff template's headings (and of summaries made before templates)
    private static var handoffTitles: [String: String] {
        [
            "overview": L10n.text("Overview", zhHans: "概览"),
            "requirements and approach changes": L10n.text("Requirements and approach changes", zhHans: "需求与方案变化"),
            "key decisions and evidence": L10n.text("Key decisions and evidence", zhHans: "关键决策与依据"),
            "completed work and verification": L10n.text("Completed work and verification", zhHans: "已完成与验证"),
            "handoff": L10n.text("Handoff", zhHans: "交接"),
            "outcome": L10n.text("Outcome", zhHans: "成果"),
            "next steps": L10n.text("Next steps", zhHans: "下一步"),
        ]
    }
}

/// Inline Markdown (bold, italics, code, links) with `[#n]` citations turned into small mono
/// links to the message. Lightweight for list items; whole sections use `MarkdownRichText`.
struct ReviewInlineText: View {
    let text: String
    var size: CGFloat = 12
    var weight: Font.Weight = .regular
    var color: Color = .primary
    /// Citation color (on the brand-filled hero the brand color would vanish)
    var linkColor: Color = Theme.brandFg

    var body: some View {
        Text(Self.attributed(text, size: size, linkColor: linkColor))
            .font(Theme.font.themed(size, weight))
            .foregroundStyle(color)
            .tint(linkColor)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    static func attributed(_ text: String, size: CGFloat, linkColor: Color = Theme.brandFg) -> AttributedString {
        let linked = SummaryReferences.linkify(text, scheme: summaryMessageScheme)
        var value = (try? AttributedString(
            markdown: linked,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in value.runs where run.link?.scheme == summaryMessageScheme {
            value[run.range].font = Theme.font.themedMono(max(9, size - 2), .medium)
            value[run.range].foregroundColor = linkColor
        }
        return value
    }
}

/// Card chrome of a review block: title with its icon and an optional count, then the content
struct ReviewCard<Content: View, Accessory: View>: View {
    let title: String
    let icon: String
    var tint: Color = Theme.brandFg
    var count: Int?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(Theme.font.themed(11, .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(title)
                    .font(Theme.font.themed(13, .semibold))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(Theme.font.themedMono(10.5, .medium))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 6)
                accessory()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                        .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
                .themeCardShadow())
    }
}

extension ReviewCard where Accessory == EmptyView {
    init(
        title: String, icon: String, tint: Color = Theme.brandFg, count: Int? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, icon: icon, tint: tint, count: count, accessory: { EmptyView() }, content: content)
    }
}

/// Bulleted items with a soft marker, one per line of thought
struct ReviewBulletList: View {
    let items: [String]
    var marker: Color = Theme.brandFg

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Circle()
                        .fill(marker.opacity(0.75))
                        .frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    ReviewInlineText(text: item)
                }
            }
        }
    }
}

/// Vertical timeline for "how the approach evolved": a rail with a dot per step, the last step
/// (the final position) filled
struct ReviewTimeline: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let last = index == steps.count - 1
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(last ? Theme.brand : Theme.surface)
                            .overlay(Circle().strokeBorder(Theme.brand, lineWidth: 1.5))
                            .frame(width: 10, height: 10)
                            .padding(.top, 4)
                        if !last {
                            Rectangle()
                                .fill(Theme.brand.opacity(0.25))
                                .frame(width: 1.5)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 10)
                    ReviewInlineText(text: step, weight: last ? .medium : .regular)
                        .padding(.bottom, last ? 0 : 14)
                }
            }
        }
    }
}
