import EurekaIngest
import EurekaKit
import SwiftUI

/// One turn's tool/search trail row: collapsed to a one-line summary by default (step count +
/// category overview), click to expand the step list.
///
/// **Thinking text availability varies by source** (the old comment's "never available locally"
/// only holds for Claude): Claude's `thinking` blocks have their body stripped when written to disk
/// (only the encrypted signature remains), so the trail is the only substitute for "what it did
/// this turn"; Codex / Kimi / Qwen have real thinking text, which goes through `ThinkingRowView`.
struct TurnTrailRowView: View {
    let message: TranscriptMessage
    var isMatch = false
    /// Expansion state is lifted to SessionDetailView (survives LazyVStack recycling; cleared on
    /// session switch)
    @Binding var expandedTrails: Set<Int>

    /// Auto-expands on a search hit (the hit may be hidden inside the steps)
    private var isExpanded: Bool {
        expandedTrails.contains(message.id) || (isMatch && !message.steps.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    if expandedTrails.contains(message.id) {
                        expandedTrails.remove(message.id)
                    } else {
                        expandedTrails.insert(message.id)
                    }
                }
            } label: {
                // Light gold pill (mockup: the trail collapse bar drops purple to stand apart from
                // the global accent)
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(Theme.font.themed(8, .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: "wrench.adjustable")
                        .font(Theme.font.themed(8.5))
                    Text(L10n.format(
                        "This turn · %@ steps",
                        zhHans: "本轮轨迹 · %@ 步",
                        String(message.steps.count)))
                        .font(Theme.font.themed(10, .medium))
                    Text(kindSummary)
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(Theme.goldFg.opacity(0.75))
                        .lineLimit(1)
                    if errorCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "exclamationmark.circle")
                                .font(Theme.font.themed(8.5))
                            Text(L10n.format("%@ failed", zhHans: "%@ 失败", String(errorCount)))
                                .font(Theme.font.themed(9.5))
                        }
                        .foregroundStyle(Theme.failureRed)
                    }
                }
                .foregroundStyle(Theme.goldFg)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Theme.gold.opacity(0.15)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 2.5) {
                    ForEach(Array(message.steps.enumerated()), id: \.offset) { _, step in
                        stepRow(step)
                    }
                }
                .padding(.leading, 13)
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isMatch ? Theme.gold.opacity(0.85) : .clear, lineWidth: 1.5))
    }

    private func stepRow(_ step: ToolStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: step.kind.icon)
                .font(Theme.font.themed(8.5))
                .frame(width: 12)
                .foregroundStyle(step.isError ? Color.red.opacity(0.8) : Theme.brandFg.opacity(0.55))
            Text(step.name)
                .font(Theme.font.themed(10, .semibold))
                .foregroundStyle(step.isError ? Color.red.opacity(0.9) : Theme.brandFg.opacity(0.75))
                .lineLimit(1)
            if !step.detail.isEmpty {
                Text(step.detail)
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if step.isError {
                Image(systemName: "exclamationmark.circle")
                    .font(Theme.font.themed(8.5))
                    .foregroundStyle(.red.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
    }

    /// Category overview, e.g. "Read 5 · Commands 3 · Edit 2" (in order of appearance, non-zero
    /// kinds only)
    private var kindSummary: String {
        var order: [ToolStep.Kind] = []
        var counts: [ToolStep.Kind: Int] = [:]
        for step in message.steps {
            if counts[step.kind] == nil { order.append(step.kind) }
            counts[step.kind, default: 0] += 1
        }
        return order.map { "\($0.label) \(counts[$0]!)" }.joined(separator: " · ")
    }

    private var errorCount: Int {
        message.steps.lazy.filter(\.isError).count
    }
}

// MARK: - Thinking text row

/// Model thinking text: collapsed by default to a one-line first-sentence preview; click to see it
/// all.
///
/// Only Codex (`event_msg/agent_reasoning`) / Kimi (`part.type == "think"`) /
/// Qwen (`{text, thought:true}`) produce it; Claude strips it when writing to disk, so it never appears.
/// Deliberately **collapsed by default + dashed purple left spine**: thinking isn't the answer and shouldn't compete with the body for visual weight,
/// but "what it thought about this turn" should still be recognizable at a glance.
struct ThinkingRowView: View {
    let message: TranscriptMessage
    var isMatch = false
    /// Shares one expansion set with trails (both keyed by `TranscriptMessage.id`, so they never
    /// collide)
    @Binding var expanded: Set<Int>

    /// Auto-expands on a search hit (the hit may be hidden in the collapsed second half)
    private var isExpanded: Bool {
        expanded.contains(message.id) || isMatch
    }

    /// Collapsed preview: first sentence/line, just enough to see where the reasoning is heading
    private var preview: String {
        let firstLine = message.text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? message.text
        return firstLine.count <= 72 ? firstLine : String(firstLine.prefix(72)) + "…"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Dashed spine: distinct from error messages' solid red spine (that's fact, this is
            // process)
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.brand.opacity(0.35))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        if expanded.contains(message.id) {
                            expanded.remove(message.id)
                        } else {
                            expanded.insert(message.id)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(Theme.font.themed(8, .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(L10n.text("💭 Thinking", zhHans: "💭 思考"))
                            .font(Theme.font.themed(10, .medium))
                        if !isExpanded {
                            Text(preview)
                                .font(Theme.font.themed(9.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.brandFg.opacity(0.7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Text(message.text)
                        .font(Theme.font.themed(11.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        // Multi-line text must lock its intrinsic height, or it gets squeezed back
                        // to one line (AuditView hit this)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isMatch ? Theme.gold.opacity(0.85) : .clear, lineWidth: 1.5))
    }
}

