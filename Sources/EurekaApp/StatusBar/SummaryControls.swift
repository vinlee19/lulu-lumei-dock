import EurekaIngest
import EurekaKit
import EurekaSummary
import SwiftUI

/// "AI Summary" split button: the primary half runs the remembered executor, the chevron opens
/// the executor picker (and picking remembers it). Before the first use there is no remembered
/// executor, so the whole control opens the picker. The picker is a themed popover rather than a
/// system menu, which ignored the style (a frosted macOS menu under a Neo-Brutalism capsule).
/// Classic is a brand-tinted capsule; brutal an ink-outlined brand capsule with the hard shadow on
/// the shape only.
struct SummarizeSplitButton: View {
    @ObservedObject var summaries: SessionSummaryService
    let session: AgentSessionInfo
    /// Called after a run was requested (the detail view switches to the summary tab)
    var onStart: () -> Void = {}
    /// Narrow layouts drop the executor name from the title (the picker still shows it)
    var compact = false

    @State private var showPicker = false
    @State private var hovering = false

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
                "Summarize this session with %@ (the arrow picks another CLI)",
                zhHans: "用 %@ 总结这个会话（点箭头换 CLI）", preferred.displayName)
        }
        return L10n.text("Pick a local CLI to summarize this session", zhHans: "选择一个本地 CLI 来总结这个会话")
    }

    var body: some View {
        Group {
            if preferred == nil && !isRunning {
                SecondaryButton(title: primaryTitle, icon: "sparkles", help: help) { showPicker.toggle() }
            } else {
                split
            }
        }
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            SummaryExecutorPicker(summaries: summaries) { kind in
                showPicker = false
                summaries.summarize(session, with: kind)
                onStart()
            }
        }
        .disabled(!summaries.isSupported(session))
    }

    private var split: some View {
        let hard = ThemeStyle.current.isHardEdged
        let foreground = hard ? Theme.onBrand : Theme.brandFg
        let divider = hard ? Theme.ink : Theme.brand.opacity(0.3)
        return HStack(spacing: 0) {
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
            Rectangle().fill(divider).frame(width: hard ? Theme.cardBorderWidth : 0.8, height: 26)
            Button { showPicker.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(Theme.font.themed(8, .bold))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("Pick another CLI", zhHans: "换一个 CLI"))
        }
        .foregroundStyle(foreground)
        .background(
            Capsule()
                .fill(hard ? Theme.brand : Theme.brandFill(hovering ? 0.18 : 0.12))
                .themeControlShadow())
        .overlay(
            Capsule().strokeBorder(
                hard ? Theme.ink : Theme.brand.opacity(0.35),
                lineWidth: hard ? Theme.cardBorderWidth : 0.8))
        .onHover { hovering = $0 }
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
}

/// Secondary button that opens the executor picker (the failed-run card's "Use another CLI")
struct SummaryExecutorPickerButton: View {
    @ObservedObject var summaries: SessionSummaryService
    let title: String
    var icon: String?
    let onPick: (SummaryExecutorKind) -> Void

    @State private var showPicker = false

    var body: some View {
        SecondaryButton(title: title, icon: icon) { showPicker.toggle() }
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                SummaryExecutorPicker(summaries: summaries) { kind in
                    showPicker = false
                    onPick(kind)
                }
            }
    }
}

/// Themed executor list for the popovers (same row language as the session list's source picker):
/// CLI logo, name, version and a check on the remembered one; unavailable CLIs stay listed, dimmed,
/// with the reason underneath, so nothing silently disappears.
struct SummaryExecutorPicker: View {
    @ObservedObject var summaries: SessionSummaryService
    let onPick: (SummaryExecutorKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text("Summarize with", zhHans: "选择总结执行器"))
                .font(Theme.font.themed(9.5, .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 7)
                .padding(.bottom, 2)
            ForEach(SummaryExecutorKind.allCases) { kind in
                row(kind)
            }
            Divider().padding(.vertical, 3)
            Button {
                summaries.refreshExecutors()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.clockwise")
                        .font(Theme.font.themed(10, .semibold))
                        .frame(width: 14)
                    Text(L10n.text("Check installed CLIs again", zhHans: "重新检测已安装的 CLI"))
                        .font(Theme.font.themed(11))
                    Spacer(minLength: 0)
                    if summaries.probing { ProgressView().controlSize(.mini) }
                }
                .foregroundStyle(.secondary)
                .modifier(PickerRowChrome(selected: false))
            }
            .buttonStyle(.plain)
            .disabled(summaries.probing)
        }
        .padding(8)
        .frame(width: 270)
        .background(
            ThemeStyle.current.isHardEdged
                ? AnyShapeStyle(Theme.surface)
                : AnyShapeStyle(
                    LinearGradient(
                        colors: [Theme.brand.opacity(0.06), Theme.gold.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    private func row(_ kind: SummaryExecutorKind) -> some View {
        let availability = summaries.availability[kind]
        let available = availability?.isAvailable == true
        let selected = summaries.preferredExecutor == kind && available
        let checking = availability == nil || (summaries.probing && !available)
        return Button {
            onPick(kind)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                SourceBadge(source: kind.source, size: 14)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(kind.displayName)
                            .font(Theme.font.themed(11, selected ? .semibold : .regular))
                        if let version = availability?.executor?.version {
                            Text(version)
                                .font(Theme.font.themedMono(10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if checking {
                        Text(L10n.text("Checking…", zhHans: "检测中…"))
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(.tertiary)
                    } else if !available, let reason = availability?.reason {
                        Text(reason)
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(Theme.font.themed(8, .bold))
                        .foregroundStyle(Theme.brandFg)
                }
            }
            .opacity(available || checking ? 1 : 0.6)
            .modifier(PickerRowChrome(selected: selected))
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }
}

/// Row padding, selected fill and hover tint shared by the picker popovers in this file
struct PickerRowChrome: ViewModifier {
    let selected: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7)
            .padding(.vertical, 4.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ThemeStyle.current.isHardEdged ? 0 : 6, style: .continuous)
                    .fill(selected
                        ? Theme.brandFill(0.12)
                        : (hovering && isEnabled ? Theme.brandFill(0.07) : .clear)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Executor choices for the session row's context menu (a native context menu can't host the
/// themed picker). Each item says why it is unavailable instead of silently disappearing.
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

/// Optional `--model` for one executor: free text plus a themed list of the names the CLI itself
/// offers (see `SummaryModelCatalog`). Claude and Codex lists are cheap and load on appear, so a
/// known default shows in the placeholder; OpenCode's list loads only when opened.
struct SummaryModelField: View {
    @ObservedObject var summaries: SessionSummaryService
    let kind: SummaryExecutorKind

    @State private var showList = false
    @FocusState private var focused: Bool

    private var text: Binding<String> {
        Binding(
            get: { summaries.models[kind] ?? "" },
            set: { summaries.models[kind] = $0 })
    }

    private var available: Bool { summaries.availability[kind]?.isAvailable == true }

    private var placeholder: String {
        if let model = summaries.modelOptions[kind]?.first(where: \.isDefault)?.value {
            return L10n.format("Default: %@", zhHans: "默认：%@", model)
        }
        return L10n.text("Model (optional)", zhHans: "模型（可选）")
    }

    var body: some View {
        let hard = ThemeStyle.current.isHardEdged
        HStack(spacing: 4) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(Theme.font.themedMono(10.5))
                .tint(Theme.brand)
                .focused($focused)
            if !text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(Theme.font.themed(10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help(L10n.text("Use the CLI's default model", zhHans: "使用 CLI 的默认模型"))
            }
            Button {
                summaries.loadModelOptions(for: kind)
                showList.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(Theme.font.themed(8, .bold))
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.brandFg)
            .disabled(!available)
            .help(L10n.text("Models this CLI offers", zhHans: "这个 CLI 提供的模型"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(width: 200, height: 24)
        .background(RoundedRectangle(cornerRadius: hard ? 0 : 6, style: .continuous).fill(Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: hard ? 0 : 6, style: .continuous)
                .strokeBorder(
                    hard ? Theme.ink : (focused ? Theme.brand.opacity(0.6) : Theme.hairline),
                    lineWidth: hard ? max(1, Theme.cardBorderWidth - 0.5) : 1))
        .help(L10n.text("Passed to the CLI as --model; leave empty for its default", zhHans: "作为 --model 传给 CLI；留空则用它的默认模型"))
        .popover(isPresented: $showList, arrowEdge: .bottom) {
            SummaryModelList(summaries: summaries, kind: kind) { showList = false }
        }
        .onAppear {
            if kind != .opencode, available { summaries.loadModelOptions(for: kind) }
        }
        .onChange(of: available) { _, isAvailable in
            if kind != .opencode, isAvailable { summaries.loadModelOptions(for: kind) }
        }
    }
}

/// The model field's popover: "CLI default" first, then the CLI's own names (narrowed by what is
/// typed in the field), and where the list comes from
struct SummaryModelList: View {
    @ObservedObject var summaries: SessionSummaryService
    let kind: SummaryExecutorKind
    var onDone: () -> Void = {}

    private var current: String {
        (summaries.models[kind] ?? "").trimmingCharacters(in: .whitespaces)
    }

    private var options: [SummaryModelOption] { summaries.modelOptions[kind] ?? [] }

    /// Typing narrows the list, unless the text already is one of the names
    private var shown: [SummaryModelOption] {
        guard !current.isEmpty, !options.contains(where: { $0.value == current }) else { return options }
        return options.filter {
            $0.value.localizedCaseInsensitiveContains(current)
                || ($0.label?.localizedCaseInsensitiveContains(current) ?? false)
        }
    }

    private var sourceNote: String {
        switch kind {
        case .claude:
            return L10n.text(
                "Claude Code's aliases from its --help; any full model name works too.",
                zhHans: "Claude Code --help 里的模型别名；也可以直接填完整模型名。")
        case .codex:
            return L10n.text(
                "From Codex's own model cache (models_cache.json).",
                zhHans: "来自 Codex 自己的模型缓存（models_cache.json）。")
        case .opencode:
            return L10n.text("From `opencode models`.", zhHans: "来自 `opencode models`。")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.format("%@ models", zhHans: "%@ 的模型", kind.displayName))
                .font(Theme.font.themed(9.5, .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 7)
                .padding(.bottom, 2)
            pick(nil)
            Divider().padding(.vertical, 3)
            if summaries.loadingModels.contains(kind) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L10n.text("Reading the model list…", zhHans: "正在读取模型列表…"))
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
            } else if shown.isEmpty {
                Text(options.isEmpty
                    ? L10n.text("This CLI listed no models; type a name instead.", zhHans: "这个 CLI 没有列出模型，可以直接输入名字。")
                    : L10n.text("No model matches the text in the field.", zhHans: "没有和输入匹配的模型。"))
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { option in pick(option) }
                    }
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(sourceNote)
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 7)
                .padding(.top, 4)
        }
        .padding(8)
        .frame(width: 300)
        .background(
            ThemeStyle.current.isHardEdged
                ? AnyShapeStyle(Theme.surface)
                : AnyShapeStyle(
                    LinearGradient(
                        colors: [Theme.brand.opacity(0.06), Theme.gold.opacity(0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    /// One choice; nil = the CLI's default (empty field)
    private func pick(_ option: SummaryModelOption?) -> some View {
        let selected = option.map { $0.value == current } ?? current.isEmpty
        return Button {
            summaries.models[kind] = option?.value ?? ""
            onDone()
        } label: {
            HStack(spacing: 6) {
                if let option {
                    Text(option.value)
                        .font(Theme.font.themedMono(10.5, selected ? .semibold : .regular))
                        .lineLimit(1).truncationMode(.middle)
                    if let label = option.label {
                        Text(label)
                            .font(Theme.font.themed(10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if option.isDefault {
                        TagChip(L10n.text("Default", zhHans: "默认"), neutral: true)
                    }
                } else {
                    Text(L10n.text("CLI default", zhHans: "使用 CLI 默认"))
                        .font(Theme.font.themed(11, selected ? .semibold : .regular))
                }
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark")
                        .font(Theme.font.themed(8, .bold))
                        .foregroundStyle(Theme.brandFg)
                }
            }
            .modifier(PickerRowChrome(selected: selected))
        }
        .buttonStyle(.plain)
    }
}
