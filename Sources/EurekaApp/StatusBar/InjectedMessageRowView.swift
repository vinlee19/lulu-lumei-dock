import EurekaIngest
import EurekaKit
import SwiftUI

/// A user turn the harness injected (task notification, a message relayed from another session,
/// command output…) rather than something the user typed. It folds to one muted line with a
/// preview so it does not read as the user speaking; tapping expands the raw text. Shares the
/// transcript's expansion set with thinking rows and turn trails (all keyed by message id).
struct InjectedMessageRowView: View {
    let message: TranscriptMessage
    var isMatch = false
    @Binding var expanded: Set<Int>

    /// Opens on a search hit so the match is visible
    private var isExpanded: Bool {
        expanded.contains(message.id) || isMatch
    }

    private var preview: String {
        let firstLine = message.text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? message.text
        return firstLine.count <= 80 ? firstLine : String(firstLine.prefix(80)) + "…"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.35))
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
                        Image(systemName: "gearshape")
                            .font(Theme.font.themed(9))
                        Text(L10n.text("Injected message", zhHans: "注入消息"))
                            .font(Theme.font.themed(10, .medium))
                        if !isExpanded {
                            Text(preview)
                                .font(Theme.font.themedMono(9.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.text(
                    "Added by the harness, not typed by you. Click to show the raw text.",
                    zhHans: "由工具链注入，不是你输入的内容；点开查看原文"))
                if isExpanded {
                    Text(message.text)
                        .font(Theme.font.themedMono(10))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Width of the session detail pane, read to decide whether the outline still fits
struct DetailWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
