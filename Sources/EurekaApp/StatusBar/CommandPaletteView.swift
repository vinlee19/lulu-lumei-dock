import EurekaKit
import SwiftUI

/// ⌘K global search overlay: input field + results grouped by kind; ↑↓ to move / Return to jump /
/// Esc to close.
struct CommandPaletteView: View {
    @ObservedObject var service: CommandPaletteService
    var onClose: () -> Void
    /// Message-level positioning for session-body hits: `revealMessage` is an instance method of
    /// SessionBrowserService, which can't travel through a notification (notifications carry only
    /// object/userInfo, not closures), so PopoverRootView injects it.
    var onRevealMessage: ((String, Int) -> Void)? = nil

    @State private var selection = 0
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(L10n.text("Search sessions / Skills / Memory / instructions / Plans…", zhHans: "搜索会话 / 技能 / 记忆 / 指令 / 计划…"), text: $service.query)
                    .textFieldStyle(.plain)
                    .font(Theme.font.themed(14))
                    .focused($inputFocused)
                    .onSubmit { route(at: selection) }
                if service.searching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if !service.hits.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(service.hits.enumerated()), id: \.element.id) { idx, hit in
                                row(hit, selected: idx == selection)
                                    .id(idx)
                                    .onTapGesture { route(at: idx) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selection) { _, idx in proxy.scrollTo(idx) }
                }
            } else if service.query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
                !service.searching {
                Divider()
                Text(L10n.text("No matches", zhHans: "没有匹配结果"))
                    .font(Theme.font.themed(12))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 18)
            }
        }
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.card)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.card)
                        .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth)))
        .shadow(color: .black.opacity(0.25), radius: 22, y: 8)
        .onAppear { inputFocused = true }
        .onChange(of: service.hits) { _, _ in selection = 0 }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(0, service.hits.count - 1)); return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0); return .handled
        }
        .onKeyPress(.escape) { onClose(); return .handled }
    }

    private func row(_ hit: CommandPaletteService.Hit, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(hit.kind.label)
                .font(Theme.font.themed(9, .medium))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule().fill(Theme.brandFill(0.10)))
                .foregroundStyle(Theme.brandFg)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.title).font(Theme.font.themed(12.5, .medium)).lineLimit(1)
                if let snippet = hit.snippet {
                    Text(snippet).font(Theme.font.themed(10.5))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let subtitle = hit.subtitle {
                Text(subtitle).font(Theme.font.themed(10)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.tile)
                .fill(selected ? Theme.brandFill(0.12) : .clear))
        .contentShape(Rectangle())
    }

    /// Return/click jumps straight there: posts the matching reveal notification and closes the
    /// panel. userInfo["kind"] uses `hit.kind.revealKind` (a computed property on
    /// EurekaKit.CommandPalette.Kind) instead of a hand-written literal, so the two ends can't
    /// drift apart in spelling.
    private func route(at index: Int) {
        guard service.hits.indices.contains(index) else { return }
        let hit = service.hits[index]
        switch hit.kind {
        case .session:
            if let id = hit.sessionId {
                NotificationCenter.default.post(name: .eurekaRevealSession, object: id)
                if let idx = hit.messageIdx {
                    onRevealMessage?(id, idx)
                }
            }
        case .skill, .memory, .instruction:
            if let kind = hit.kind.revealKind {
                NotificationCenter.default.post(
                    name: .eurekaRevealKnowledge, object: hit.key, userInfo: ["kind": kind])
            }
        case .plan:
            NotificationCenter.default.post(name: .eurekaRevealPlan, object: hit.key)
        case .prompt:
            NotificationCenter.default.post(name: .eurekaRevealPrompt, object: hit.key)
        }
        onClose()
    }
}
