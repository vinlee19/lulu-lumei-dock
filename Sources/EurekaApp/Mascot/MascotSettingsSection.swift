import AppKit
import EurekaKit
import SwiftUI

/// Settings → General → "Desktop companion": look (presets + uploads), a state table that says
/// when each state shows and what it looks like (with a live preview), behavior knobs, and the
/// advanced pack folder.
struct MascotSettingsSection: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var library = MascotLibrary()
    /// Whether to cut away the solid-color background from the four corners on upload (affects only
    /// images uploaded afterwards)
    @AppStorage("mascotUploadRemovesBackground") private var removeBackground = false
    @State private var nameDraft = ""
    @State private var confirmingDelete: MascotPackInfo?
    @State private var showsAdvanced = false
    /// State whose row is playing its inline preview. The companion may sit on another display
    /// (or behind a full-screen window), so Preview must also be visible right here.
    @State private var previewing: MascotState?
    @State private var previewToken = 0

    private let columns = [GridItem(.adaptive(minimum: 78, maximum: 96), spacing: 8)]

    /// State table grouping: what drives each state, in the order users meet them
    private static let stateGroups: [(title: String, states: [MascotState])] = [
        (L10n.text("Follows your tasks", zhHans: "跟随任务"), [.working, .waiting, .success, .error]),
        (L10n.text("Idle and bedtime", zhHans: "空闲作息"), [.idle, .sleeping, .night]),
        (L10n.text("Interaction and nudges", zhHans: "互动与提醒"), [.poke, .wake, .relax]),
    ]

    private static let sleepOptions = [1, 5, 15, 30, 0]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.row) {
            Toggle(
                L10n.text("Show the desktop companion", zhHans: "显示桌面伙伴"),
                isOn: $settings.mascotEnabled)
            if settings.mascotEnabled {
                lookSection
                Divider().opacity(0.5)
                stateSection
                Divider().opacity(0.5)
                behaviorSection
                DisclosureGroup(isExpanded: $showsAdvanced) {
                    advancedSection
                } label: {
                    Text(L10n.text("Advanced", zhHans: "高级"))
                        .font(Theme.font.themed(11, .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            library.refresh()
            syncSelection()
        }
        .onChange(of: settings.mascotPack) { _, _ in syncSelection() }
        .confirmationDialog(
            confirmingDelete.map {
                L10n.format(
                    "Delete the companion \"%@\"? Its images move to the Trash.",
                    zhHans: "删除形象「%@」？图片会移到废纸篓。", $0.name)
            } ?? "",
            isPresented: Binding(
                get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.text("Delete", zhHans: "删除"), role: .destructive) {
                if let info = confirmingDelete {
                    if settings.mascotPack == info.id {
                        settings.mascotPack = MascotPackLoader.builtInID
                    }
                    library.delete(packID: info.id)
                }
            }
            Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) {}
        }
    }

    // MARK: - Look

    @ViewBuilder
    private var lookSection: some View {
        sectionHeader(L10n.text("Look", zhHans: "形象"))
        packGrid(
            title: L10n.text("Presets", zhHans: "预设形象"),
            packs: library.presetPacks, showsUpload: false)
        packGrid(
            title: L10n.text("My companions", zhHans: "我的形象"),
            packs: library.customPacks, showsUpload: true)
        Toggle(
            L10n.text(
                "Remove a solid background on upload (for images on white or a flat color)",
                zhHans: "上传时自动去除纯色背景（适合白底 / 纯色底的图）"),
            isOn: $removeBackground)
            .font(Theme.font.themed(11))
        if let error = library.lastError {
            Text(error)
                .font(Theme.font.themed(10))
                .foregroundStyle(.orange)
        }
        if let editing = library.editing, editing.id == settings.mascotPack {
            nameRow(editing)
        }
    }

    // MARK: - States

    @ViewBuilder
    private var stateSection: some View {
        sectionHeader(
            L10n.text("States", zhHans: "状态"),
            detail: L10n.text(
                "When each state shows and what it looks like. Preview plays it here and on the companion.",
                zhHans: "每个状态何时出现、显示什么；点「预览」在这里播放，桌面上的伙伴也会同步演一遍。"))
        let editing = library.editing.flatMap { $0.id == settings.mascotPack ? $0 : nil }
        ForEach(Self.stateGroups, id: \.title) { group in
            Text(group.title)
                .font(Theme.font.themed(10, .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            VStack(spacing: 0) {
                ForEach(Array(group.states.enumerated()), id: \.element) { index, state in
                    if index > 0 { Divider().opacity(0.4) }
                    stateRow(state, editing: editing)
                }
            }
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .fill(Theme.surfaceSecondary))
        }
        if editing == nil {
            Text(L10n.text(
                "Preset art can't be changed. Upload an image under My companions to make one you can customize state by state.",
                zhHans: "预设形象的动作不可修改；在「我的形象」上传一张图，即可逐个状态换图。"))
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stateRow(_ state: MascotState, editing: MascotLibrary.Editing?) -> some View {
        let art = library.stateArt[state]
        let editable = editing != nil && MascotManifestEditor.editableStates.contains(state)
        let isPreviewing = previewing == state
        return HStack(spacing: 8) {
            Group {
                if isPreviewing, let art {
                    MascotAnimationView(animation: art.animation, playback: art.playback)
                } else if let image = editing?.images[state] ?? art?.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: isPreviewing ? 72 : 30, height: isPreviewing ? 72 : 30)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isPreviewing)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(Self.title(for: state))
                        .font(Theme.font.themed(11, .medium))
                    Text(source(for: state, art: art, editing: editable ? editing : nil))
                        .font(Theme.font.themed(9))
                        .foregroundStyle(.tertiary)
                }
                Text(trigger(for: state))
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(isInactive(state) ? .tertiary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            SecondaryButton(
                title: isPreviewing
                    ? L10n.text("Playing…", zhHans: "播放中…")
                    : L10n.text("Preview", zhHans: "预览"),
                icon: "play.fill", classic: .push
            ) {
                preview(state)
            }
            if editable, let editing {
                SecondaryButton(title: L10n.text("Change…", zhHans: "更换…"), classic: .push) {
                    guard let url = Self.pickImage(message: L10n.format(
                        "Choose the image shown for \"%@\"",
                        zhHans: "选择「%@」时显示的图片", Self.title(for: state)))
                    else { return }
                    library.setImage(
                        for: state, packID: editing.id, from: url,
                        removeBackground: removeBackground)
                }
                if state != .idle, editing.files[state] != nil {
                    SecondaryButton(title: L10n.text("Reset", zhHans: "恢复"), classic: .push) {
                        library.resetImage(for: state, packID: editing.id)
                    }
                }
            }
        }
        .padding(.vertical, 5)
    }

    /// Plays the state inline and on the live companion for the same few seconds
    private func preview(_ state: MascotState) {
        previewing = state
        previewToken &+= 1
        let token = previewToken
        NotificationCenter.default.post(name: .eurekaPreviewMascotState, object: state.rawValue)
        DispatchQueue.main.asyncAfter(deadline: .now() + MascotViewModel.previewSeconds) {
            if previewToken == token { previewing = nil }
        }
    }

    /// Where a state's art comes from: its own (with the variant count) or a fallback state
    private func source(
        for state: MascotState, art: MascotLibrary.StateArt?, editing: MascotLibrary.Editing?
    ) -> String {
        if let editing {
            if state == .idle {
                return L10n.text("Base image", zhHans: "基础形象")
            }
            if editing.files[state] != nil { return L10n.text("Set separately", zhHans: "已单独设置") }
            let source = MascotManifestEditor.effectiveSource(for: state, files: editing.files) ?? .idle
            return L10n.format("Uses \"%@\"", zhHans: "沿用「%@」", Self.title(for: source))
        }
        guard let art, let provider = art.provider else { return "" }
        if provider != state {
            return L10n.format("Uses \"%@\"", zhHans: "沿用「%@」", Self.title(for: provider))
        }
        return art.variantCount > 1
            ? L10n.format("%@ moves", zhHans: "%@ 个动作", String(art.variantCount))
            : L10n.text("Own art", zhHans: "专属动画")
    }

    /// Plain-language trigger, reflecting the behavior settings below
    private func trigger(for state: MascotState) -> String {
        let night = Self.nightRange
        let minutes = settings.mascotSleepMinutes
        switch state {
        case .working:
            return settings.mascotNightMode
                ? L10n.format("A task is running (late at night it turns \"%@\")",
                              zhHans: "有任务在运行（深夜时改为「%@」）", Self.title(for: .night))
                : L10n.text("A task is running", zhHans: "有任务在运行")
        case .waiting:
            return L10n.text(
                "A task is waiting for your permission or answer",
                zhHans: "有任务在等你确认权限或回答问题")
        case .success:
            return L10n.text("A task finished successfully (about 2.5 s)", zhHans: "任务成功结束（约 2.5 秒）")
        case .error:
            return L10n.text("A task failed (about 2.5 s)", zhHans: "任务失败（约 2.5 秒）")
        case .idle:
            return L10n.text("No task is running", zhHans: "没有任务在运行")
        case .sleeping:
            switch (minutes > 0, settings.mascotNightMode) {
            case (true, true):
                return L10n.format("Idle for %1$@ min, or no task late at night (%2$@)",
                                   zhHans: "闲置超过 %1$@ 分钟，或深夜（%2$@）没有任务", String(minutes), night)
            case (true, false):
                return L10n.format("Idle for %@ min", zhHans: "闲置超过 %@ 分钟", String(minutes))
            case (false, true):
                return L10n.format("No task late at night (%@)", zhHans: "深夜（%@）没有任务", night)
            case (false, false):
                return L10n.text("Off: never falls asleep", zhHans: "已关闭：不会入睡")
            }
        case .night:
            return settings.mascotNightMode
                ? L10n.format("A task is still running late at night (%@)", zhHans: "深夜（%@）仍有任务在运行", night)
                : L10n.text("Off: late-night mode is disabled", zhHans: "已关闭：深夜模式未开启")
        case .poke:
            return L10n.text("Click it", zhHans: "点它一下")
        case .wake:
            return L10n.text("Move the mouse while it sleeps", zhHans: "睡着时移动鼠标")
        case .relax:
            return L10n.text(
                "Break reminder after a long stretch of work (wellness)",
                zhHans: "连续工作较久时的休息提醒（健康提醒）")
        }
    }

    /// States the current behavior settings can never reach
    private func isInactive(_ state: MascotState) -> Bool {
        switch state {
        case .night: return !settings.mascotNightMode
        case .sleeping: return settings.mascotSleepMinutes == 0 && !settings.mascotNightMode
        default: return false
        }
    }

    private static var nightRange: String {
        String(format: "%02d:00–%02d:00",
               MascotBaseResolver.nightHours.start, MascotBaseResolver.nightHours.end)
    }

    // MARK: - Behavior

    @ViewBuilder
    private var behaviorSection: some View {
        sectionHeader(L10n.text("Behavior", zhHans: "行为"))
        HStack {
            Text(L10n.text("Fall asleep after idle", zhHans: "闲置多久后入睡"))
                .font(Theme.font.themed(11))
            Spacer(minLength: 8)
            Picker("", selection: $settings.mascotSleepMinutes) {
                ForEach(Self.sleepOptions, id: \.self) { minutes in
                    Text(minutes > 0
                        ? L10n.format("%@ min", zhHans: "%@ 分钟", String(minutes))
                        : L10n.text("Never", zhHans: "从不"))
                        .tag(minutes)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 110)
        }
        Toggle(
            L10n.format(
                "Late-night mode (%@): drowsy while working, asleep when idle",
                zhHans: "深夜模式（%@）：工作时犯困，没任务就睡觉", Self.nightRange),
            isOn: $settings.mascotNightMode)
            .font(Theme.font.themed(11))
        Toggle(
            L10n.text(
                "Speech bubbles for finished / failed tasks and break reminders",
                zhHans: "完成 / 出错 / 休息提醒时显示气泡"),
            isOn: $settings.mascotBubbles)
            .font(Theme.font.themed(11))
        HStack {
            Text(L10n.text("Size", zhHans: "尺寸"))
                .font(Theme.font.themed(11))
            Spacer(minLength: 8)
            ThemedSegmentedPicker(
                selection: Binding(
                    get: { MascotSize.resolve(settings.mascotSize) },
                    set: { settings.mascotSize = $0.rawValue }),
                options: MascotSize.allCases, label: \.title, classicWidth: 150)
        }
        HStack {
            Text(L10n.text(
                "Drag it anywhere; right-click to hide it.",
                zhHans: "按住可拖到任意位置，右键可隐藏。"))
                .font(Theme.font.themed(10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            SecondaryButton(
                title: L10n.text("Reset position", zhHans: "恢复默认位置"), classic: .push
            ) {
                NotificationCenter.default.post(name: .eurekaResetMascotPosition, object: nil)
            }
        }
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(
                "For multi-frame animation, put frames in mascots/<name>/ with a manifest.json; the folder has notes and an example.",
                zhHans: "多帧动画：把帧图放进 mascots/<名字>/ 并配一个 manifest.json，文件夹里有说明与示例。"))
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("Open the animation-pack folder", zhHans: "打开动画包文件夹")) {
                MascotPackLoader.revealCustomFolder()
            }
            .controlSize(.small)
        }
        .padding(.top, 4)
    }

    // MARK: - Mascot grid

    private func sectionHeader(_ title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Theme.font.themed(12, .semibold))
            if let detail {
                Text(detail)
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func packGrid(title: String, packs: [MascotPackInfo], showsUpload: Bool) -> some View {
        Text(title)
            .font(Theme.font.themed(11, .semibold))
            .foregroundStyle(.secondary)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(packs) { info in
                PackTile(
                    name: info.name,
                    image: library.thumbnails[info.id],
                    isSelected: settings.mascotPack == info.id
                ) {
                    settings.mascotPack = info.id
                }
            }
            if showsUpload {
                UploadTile { upload() }
            }
        }
    }

    private func upload() {
        guard let url = Self.pickImage(message: L10n.text(
            "Choose an image for the desktop companion (PNG / JPG / GIF…, up to 20 MB)",
            zhHans: "选择一张图片作为桌面伙伴形象（PNG / JPG / GIF…，≤ 20MB）"))
        else { return }
        if let id = library.createPack(from: url, removeBackground: removeBackground) {
            settings.mascotPack = id
        }
    }

    // MARK: - Uploaded pack name

    private func nameRow(_ editing: MascotLibrary.Editing) -> some View {
        HStack(spacing: 6) {
            Text(L10n.text("Name", zhHans: "名称"))
                .font(Theme.font.themed(11))
            TextField(L10n.text("Companion name", zhHans: "形象名称"), text: $nameDraft)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 160)
                .onSubmit { library.rename(packID: editing.id, to: nameDraft) }
            Spacer()
            SecondaryButton(
                title: L10n.text("Delete companion", zhHans: "删除此形象"),
                destructive: true, classic: .push
            ) {
                confirmingDelete = library.customPacks.first { $0.id == editing.id }
            }
        }
    }

    /// Selection changed: an uploaded pack loads into the editing area and the name field syncs
    private func syncSelection() {
        library.select(packID: settings.mascotPack)
        nameDraft = library.editing?.name ?? ""
    }

    static func title(for state: MascotState) -> String {
        switch state {
        case .idle: return L10n.text("Idle", zhHans: "平时")
        case .working: return L10n.text("Working", zhHans: "工作中")
        case .waiting: return L10n.text("Waiting for you", zhHans: "等你确认")
        case .success: return L10n.text("Done", zhHans: "完成")
        case .error: return L10n.text("Error", zhHans: "出错")
        case .sleeping: return L10n.text("Sleeping", zhHans: "睡觉")
        case .relax: return L10n.text("Relax", zhHans: "放松")
        case .night: return L10n.text("Late night", zhHans: "深夜")
        case .poke: return L10n.text("Poked", zhHans: "被戳")
        case .wake: return L10n.text("Waking up", zhHans: "醒来")
        }
    }

    private static func pickImage(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = MascotImageImporter.allowedTypes
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// One selectable mascot: thumbnail + name, outlined in the brand color when selected
private struct PackTile: View {
    let name: String
    let image: NSImage?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.radius.tile)
                        .fill(Theme.surfaceSecondary)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(6)
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 66)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.tile)
                        .strokeBorder(
                            isSelected ? Theme.brand : Theme.hairline,
                            lineWidth: isSelected ? 2 : 1))
                Text(name)
                    .font(Theme.font.themed(10, isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
    }
}

/// The "Upload image" entry tile
private struct UploadTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.radius.tile)
                        .strokeBorder(
                            Theme.hairline,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    Image(systemName: "plus")
                        .font(Theme.font.themed(18, .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 66)
                Text(L10n.text("Upload image", zhHans: "上传图片"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
