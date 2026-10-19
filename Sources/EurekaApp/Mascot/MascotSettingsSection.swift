import AppKit
import EurekaKit
import SwiftUI

/// 设置 → 通用 →「桌面伙伴」：开关、形象选择（预设 + 我的）、上传与按状态换图。
struct MascotSettingsSection: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var library = MascotLibrary()
    /// 上传时是否从四角抠掉纯色背景（只影响之后上传的图）
    @AppStorage("mascotUploadRemovesBackground") private var removeBackground = false
    @State private var nameDraft = ""
    @State private var confirmingDelete: MascotPackInfo?

    private let columns = [GridItem(.adaptive(minimum: 78, maximum: 96), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.row) {
            Toggle("显示桌面吉祥物", isOn: $settings.mascotEnabled)
            if settings.mascotEnabled {
                packGrid(title: "预设形象", packs: library.presetPacks, showsUpload: false)
                packGrid(title: "我的形象", packs: library.customPacks, showsUpload: true)
                Toggle("上传时自动去除纯色背景（适合白底 / 纯色底的图）", isOn: $removeBackground)
                    .font(.system(size: 11))
                if let error = library.lastError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                if let editing = library.editing, editing.id == settings.mascotPack {
                    editor(editing)
                }
                builtInSummary
                Button("打开动画包文件夹") { MascotPackLoader.revealCustomFolder() }
                    .controlSize(.small)
                Text("上传一张图即可替换噜噜，各状态共用这张图并配合动作区分；"
                    + "也可以给工作中 / 等你确认 / 完成 / 出错 / 睡觉单独换图。"
                    + "多帧动画请用 mascots/<名字>/ + manifest.json（文件夹里有说明与示例）。"
                    + "拖动可移动位置，右键可隐藏。")
                    .font(.system(size: 9.5))
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
            confirmingDelete.map { "删除形象「\($0.name)」？图片会移到废纸篓。" } ?? "",
            isPresented: Binding(
                get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let info = confirmingDelete {
                    if settings.mascotPack == info.id {
                        settings.mascotPack = MascotPackLoader.builtInID
                    }
                    library.delete(packID: info.id)
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 形象网格

    @ViewBuilder
    private func packGrid(title: String, packs: [MascotPackInfo], showsUpload: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
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
        guard let url = Self.pickImage(message: "选择一张图片作为桌面伙伴形象（PNG / JPG / GIF…，≤ 20MB）")
        else { return }
        if let id = library.createPack(from: url, removeBackground: removeBackground) {
            settings.mascotPack = id
        }
    }

    // MARK: - 上传包编辑区

    @ViewBuilder
    private func editor(_ editing: MascotLibrary.Editing) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("名称")
                    .font(.system(size: 11))
                TextField("形象名称", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 160)
                    .onSubmit { library.rename(packID: editing.id, to: nameDraft) }
                Spacer()
                Button("删除此形象", role: .destructive) {
                    confirmingDelete = library.customPacks.first { $0.id == editing.id }
                }
                .controlSize(.small)
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
                    .font(.system(size: 11, weight: .medium))
                Text(detail(for: state, editing: editing))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("更换…") {
                guard let url = Self.pickImage(message: "选择「\(Self.title(for: state))」时显示的图片")
                else { return }
                library.setImage(
                    for: state, packID: editing.id, from: url, removeBackground: removeBackground)
            }
            .controlSize(.small)
            if state != .idle, editing.files[state] != nil {
                Button("恢复") { library.resetImage(for: state, packID: editing.id) }
                    .controlSize(.small)
            }
        }
    }

    private func detail(for state: MascotState, editing: MascotLibrary.Editing) -> String {
        if state == .idle { return "基础形象，其他状态默认都用它" }
        if editing.files[state] != nil { return "已单独设置" }
        let source = MascotManifestEditor.effectiveSource(for: state, files: editing.files) ?? .idle
        return "沿用「\(Self.title(for: source))」"
    }

    // MARK: - 其他

    @ViewBuilder
    private var builtInSummary: some View {
        if settings.mascotPack == MascotPackLoader.builtInID {
            let builtIn = MascotPackLoader.builtIn()
            let idleCount = builtIn.variants(for: .idle).count
            let workingCount = builtIn.variants(for: .working).count
            let waitingCount = builtIn.variants(for: .waiting).count
            Text("高频行为共 \(idleCount + workingCount + waitingCount) 种："
                + "空闲 \(idleCount) · 工作 \(workingCount) · 等待 \(waitingCount) · "
                + "\(builtIn.lookDirections.count) 向视线")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Theme.brandFg)
        }
    }

    /// 选中项变化：上传包载入编辑区，名称输入框同步
    private func syncSelection() {
        library.select(packID: settings.mascotPack)
        nameDraft = library.editing?.name ?? ""
    }

    static func title(for state: MascotState) -> String {
        switch state {
        case .idle: return "平时"
        case .working: return "工作中"
        case .waiting: return "等你确认"
        case .success: return "完成"
        case .error: return "出错"
        case .sleeping: return "睡觉"
        case .relax: return "放松"
        case .night: return "深夜"
        case .poke: return "被戳"
        case .wake: return "醒来"
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

/// 一个可选形象：缩略图 + 名称，选中时品牌色描边
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
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
    }
}

/// 「上传图片」入口格
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
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 66)
                Text("上传图片")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
