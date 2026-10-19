import EurekaKit
import SwiftUI

/// One row standing in for a run of harness background calls (memory compaction, branch-name
/// generation…). Their "title" is the harness prompt itself, so listing them one by one buries
/// the sessions the user actually started. Shared by the history page and the session list.
struct HarnessUtilityRow: View {
    let count: Int
    let subtitle: String
    var verticalPadding: CGFloat = 8

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(Theme.font.themed(11.5))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.format("%@ background calls", zhHans: "后台调用 %@ 次", String(count)))
                    .font(Theme.font.themed(12, .medium))
                Text(subtitle)
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPadding)
    }
}
