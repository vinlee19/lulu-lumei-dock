import AppKit
import EurekaKit
import SwiftUI

/// Settings → General → "Desktop companion": toggle, mascot picker (Presets + My companions),
/// upload, and per-state image swapping.
struct MascotSettingsSection: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var library = MascotLibrary()
    /// Whether to cut away the solid-color background from the four corners on upload (affects only
    /// images uploaded afterwards)
    @AppStorage("mascotUploadRemovesBackground") private var removeBackground = false
    @State private var nameDraft = ""
    @State private var confirmingDelete: MascotPackInfo?

    private let columns = [GridItem(.adaptive(minimum: 78, maximum: 96), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.row) {
            Toggle(
                L10n.text("Show the desktop companion", zhHans: "显示桌面吉祥物"),
                isOn: $settings.mascotEnabled)
            if settings.mascotEnabled {
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
                    editor(editing)
                }
                builtInSummary
                Button(L10n.text("Open the animation-pack folder", zhHans: "打开动画包文件夹")) { MascotPackLoader.revealCustomFolder() }
                    .controlSize(.small)
                Text(L10n.text(
                    "Upload one image to replace Lulu; every state shares it and the motions tell them apart. You can also set separate images for working / waiting / done / error / sleeping. For multi-frame animation use mascots/<name>/ + manifest.json (the folder has notes and an example). Drag to move it, right-click to hide it.",
                    zhHans: "上传一张图即可替换噜噜，各状态共用这张图并配合动作区分；也可以给工作中 / 等你确认 / 完成 / 出错 / 睡觉单独换图。多帧动画请用 mascots/<名字>/ + manifest.json（文件夹里有说明与示例）。拖动可移动位置，右键可隐藏。"))
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Mascot grid

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

    // MARK: - Uploaded pack editor

    @ViewBuilder
    private func editor(_ editing: MascotLibrary.Editing) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
            ForEach(MascotManifestEditor.editableStates, id: \.self) { state in
                stateRow(state, editing: editing)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .fill(Theme.surfaceSecondary))
    }

    private func stateRow(_ state: MascotState, editing: MascotLibrary.Editing) -> some View {
        HStack(spacing: 8) {
            Group {
                if let image = editing.images[state] {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.title(for: state))
                    .font(Theme.font.themed(11, .medium))
                Text(detail(for: state, editing: editing))
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SecondaryButton(title: L10n.text("Change…", zhHans: "更换…"), classic: .push) {
                guard let url = Self.pickImage(message: L10n.format(
                    "Choose the image shown for \"%@\"",
                    zhHans: "选择「%@」时显示的图片", Self.title(for: state)))
                else { return }
                library.setImage(
                    for: state, packID: editing.id, from: url, removeBackground: removeBackground)
            }
            if state != .idle, editing.files[state] != nil {
                SecondaryButton(title: L10n.text("Reset", zhHans: "恢复"), classic: .push) {
                    library.resetImage(for: state, packID: editing.id)
                }
            }
        }
    }

    private func detail(for state: MascotState, editing: MascotLibrary.Editing) -> String {
        if state == .idle {
            return L10n.text("The base image; other states use it by default", zhHans: "基础形象，其他状态默认都用它")
        }
        if editing.files[state] != nil { return L10n.text("Set separately", zhHans: "已单独设置") }
        let source = MascotManifestEditor.effectiveSource(for: state, files: editing.files) ?? .idle
        return L10n.format("Uses \"%@\"", zhHans: "沿用「%@」", Self.title(for: source))
    }

    // MARK: - Other

    @ViewBuilder
    private var builtInSummary: some View {
        if settings.mascotPack == MascotPackLoader.builtInID {
            let builtIn = MascotPackLoader.builtIn()
            let idleCount = builtIn.variants(for: .idle).count
            let workingCount = builtIn.variants(for: .working).count
            let waitingCount = builtIn.variants(for: .waiting).count
            Text(L10n.format(
                "%1$@ frequent poses: idle %2$@ · working %3$@ · waiting %4$@ · %5$@ gaze directions",
                zhHans: "高频行为共 %1$@ 种：空闲 %2$@ · 工作 %3$@ · 等待 %4$@ · %5$@ 向视线",
                String(idleCount + workingCount + waitingCount),
                String(idleCount),
                String(workingCount),
                String(waitingCount),
                String(builtIn.lookDirections.count)))
                .font(Theme.font.themed(9.5, .medium))
                .foregroundStyle(Theme.brandFg)
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
