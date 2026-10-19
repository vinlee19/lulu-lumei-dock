import EurekaIngest
import EurekaKit
import EurekaSummary
import SwiftUI

/// "AI Summary" split button: the primary half runs the remembered executor, the menu picks
/// another one (and remembers it). Before the first use there is no remembered executor, so the
/// whole control is the selector. Classic is the system split pull-down at small size; brutal is
/// an ink-outlined capsule with a divider and the hard shadow on the shape only.
struct SummarizeSplitButton: View {
    @ObservedObject var summaries: SessionSummaryService
    let session: AgentSessionInfo
    /// Called after a run was requested (the detail view switches to the summary tab)
    var onStart: () -> Void = {}
    /// Narrow layouts drop the executor name from the title (the menu still shows it)
    var compact = false

    private var preferred: SummaryExecutorKind? {
        guard let kind = summaries.preferredExecutor,
              summaries.availability[kind]?.isAvailable == true else { return nil }
        return kind
    }

    private var isRunning: Bool { summaries.live[summaries.key(session)] != nil }

    private var primaryTitle: String {
        if isRunning { return L10n.text("Summarizing…", zhHans: "总结中…") }
        guard let preferred else { return L10n.text("AI Summary", zhHans: "AI 总结") }
        if compact { return L10n.text("Summarize", zhHans: "总结") }
        return L10n.format("Summarize · %@", zhHans: "总结 · %@", preferred.displayName)
    }

    private var help: String {
        if let reason = SummarySourceSupport.unsupportedReason(session.source) { return reason }
        if isRunning { return L10n.text("Show the running summary", zhHans: "查看进行中的总结") }
        if let preferred {
            return L10n.format(
                "Summarize this session with %@ (the menu picks another CLI)",
                zhHans: "用 %@ 总结这个会话（菜单里可换 CLI）", preferred.displayName)
        }
        return L10n.text("Pick a local CLI to summarize this session", zhHans: "选择一个本地 CLI 来总结这个会话")
    }

    var body: some View {
        Group {
            if preferred == nil && !isRunning {
                MenuButton(title: primaryTitle, icon: "sparkles", help: help) { executorItems }
            } else if ThemeStyle.current.isHardEdged {
                brutal
            } else {
                Menu { executorItems } label: {
                    Label(primaryTitle, systemImage: "sparkles").font(Theme.font.themed(11))
                } primaryAction: {
                    runPreferred()
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .help(help)
            }
        }
        .disabled(!summaries.isSupported(session))
    }

    private var brutal: some View {
        HStack(spacing: 0) {
            Button(action: runPreferred) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(Theme.font.themed(10, .semibold))
                    Text(primaryTitle).font(Theme.font.themed(11, .semibold)).lineLimit(1)
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle().fill(Theme.ink).frame(width: Theme.cardBorderWidth, height: 26)
            Menu { executorItems } label: {
                Image(systemName: "chevron.down").font(Theme.font.themed(8, .bold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(height: 26)
        }
        .foregroundStyle(Theme.onBrand)
        .background(Capsule().fill(Theme.brand).themeControlShadow())
        .overlay(Capsule().strokeBorder(Theme.ink, lineWidth: Theme.cardBorderWidth))
        .fixedSize()
        .help(help)
    }

    private func runPreferred() {
        if isRunning {
            summaries.revealSummary(for: session)
            onStart()
            return
        }
        guard let preferred else { return }
        summaries.summarize(session, with: preferred)
        onStart()
    }

    @ViewBuilder
    private var executorItems: some View {
        SummaryExecutorMenuItems(summaries: summaries, session: session, onStart: onStart)
    }
}

/// Executor choices shared by the split button and the session row's context menu. Each item
/// says why it is unavailable instead of silently disappearing.
struct SummaryExecutorMenuItems: View {
    @ObservedObject var summaries: SessionSummaryService
    let session: AgentSessionInfo
    var onStart: () -> Void = {}

    var body: some View {
        Section(L10n.text("Summarize with", zhHans: "选择总结执行器")) {
            ForEach(SummaryExecutorKind.allCases) { kind in
                let availability = summaries.availability[kind]
                Button {
                    summaries.summarize(session, with: kind)
                    onStart()
                } label: {
                    if let availability, availability.isAvailable {
                        let version = availability.executor?.version.map { " \($0)" } ?? ""
                        let mark = summaries.preferredExecutor == kind ? " ✓" : ""
                        Text("\(kind.displayName)\(version)\(mark)")
                    } else if summaries.probing || availability == nil {
                        Text(L10n.format("%@ — checking…", zhHans: "%@ — 检测中…", kind.displayName))
                    } else {
                        Text(L10n.format(
                            "%@ — unavailable: %@", zhHans: "%@ — 不可用：%@",
                            kind.displayName, availability?.reason ?? ""))
                    }
                }
                .disabled(availability?.isAvailable != true)
            }
        }
        Divider()
        Button(L10n.text("Check installed CLIs again", zhHans: "重新检测已安装的 CLI")) {
            summaries.refreshExecutors()
        }
    }
}

/// Status glyph for a session row: pulsing while a summary runs, quiet once one is saved, amber
/// after a failure. Rows without summaries render nothing (unchanged pixels).
struct SummaryRowBadge: View {
    let status: SessionSummaryService.RowStatus

    var body: some View {
        switch status {
        case .running:
            Image(systemName: "sparkles")
                .font(Theme.font.themed(9.5, .semibold))
                .foregroundStyle(Theme.brandFg)
                .symbolEffect(.pulse, options: .repeating)
                .help(L10n.text("AI summary in progress", zhHans: "AI 总结进行中"))
        case .completed:
            Image(systemName: "sparkles")
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.secondary)
                .help(L10n.text("Has an AI summary", zhHans: "已有 AI 总结"))
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(Theme.font.themed(9.5))
                .foregroundStyle(Theme.goldFg)
                .help(L10n.text("The last AI summary failed", zhHans: "上次 AI 总结失败"))
        }
    }
}
