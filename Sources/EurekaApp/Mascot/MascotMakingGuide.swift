import EurekaKit
import SwiftUI

/// Settings → Desktop companion → "How to bring your own pet": the three ways in, the asset
/// requirements, and the file names the folder import recognises (read from `MascotFolderMapper`,
/// so the table can't drift from the matcher).
struct MascotMakingGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(
                "1",
                L10n.text("Just one image", zhHans: "只有一张图"),
                L10n.text(
                    "Upload image → it becomes the base look, and every state reuses it with a different motion. Swap single states later with Change… in the state table.",
                    zhHans: "点「上传图片」→ 它就是基础形象，各状态先共用这张图、靠动作区分；之后可在状态表里用「更换…」逐个换图。"))
            step(
                "2",
                L10n.text("A set of images or GIFs (recommended)", zhHans: "已有一套图或 GIF（推荐）"),
                L10n.text(
                    "Put them in one folder, name each file after its state, then Import folder. Several images of one state become a frame animation: number them (sleep-1.png, sleep-2.png) or put them in a subfolder named after the state (sleep/01.png …).",
                    zhHans: "把图放进一个文件夹，按状态给文件命名，然后点「导入文件夹」。同一状态的多张图会组成帧动画：要么加编号（sleep-1.png、sleep-2.png），要么放进以状态命名的子文件夹（sleep/01.png …）。"))
            namingTable
            step(
                "3",
                L10n.text("Full control", zhHans: "完全自定义"),
                L10n.text(
                    "Write a manifest.json in the folder for several random moves per state, captions and motion styles. Import folder uses it as is and reports any problem; Advanced → Open the animation-pack folder has a commented example.",
                    zhHans: "在文件夹里写一个 manifest.json，可给一个状态配多个随机轮换的动作、文字和动效。「导入文件夹」会直接使用并报告问题；高级 → 打开动画包文件夹里有带注释的示例。"))
            requirements
        }
        .padding(.top, 6)
    }

    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(Theme.font.themedMono(10, .bold))
                .foregroundStyle(Theme.brandFg)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.brandFill(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.font.themed(11, .semibold))
                Text(detail)
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// State → the file names import recognises
    private var namingTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(MascotManifestEditor.editableStates, id: \.self) { state in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(MascotSettingsSection.title(for: state))
                        .font(Theme.font.themed(10, .medium))
                        .frame(width: 76, alignment: .leading)
                    Text((MascotFolderMapper.aliasNames[state] ?? []).joined(separator: " · "))
                        .font(Theme.font.themedMono(9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
            }
            Text(L10n.text(
                "Names are case-insensitive; _ and spaces count as -. Only idle is required; a state without art reuses another one (Done / Error → Working → Idle, Late night → Sleeping).",
                zhHans: "不区分大小写，_ 和空格等同于 -。只有 idle（平时）是必需的；没给图的状态会沿用别的（完成 / 出错 → 工作中 → 平时，深夜 → 睡觉）。"))
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .fill(Theme.surfaceSecondary))
        .padding(.leading, 26)
    }

    private var requirements: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.text("Asset requirements", zhHans: "素材要求"))
                .font(Theme.font.themed(11, .semibold))
            ForEach(Self.requirementLines, id: \.self) { line in
                Text("· " + line)
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static var requirementLines: [String] {
        [
            L10n.text(
                "Formats: still PNG / JPG / WebP / HEIC / TIFF / BMP; animated GIF / APNG play as they are.",
                zhHans: "格式：静态图 PNG / JPG / WebP / HEIC / TIFF / BMP；动图 GIF / APNG 原样播放。"),
            L10n.text(
                "Size: square-ish, character centred, the same canvas for every state. Still images are scaled to 512 px on the long edge; each file ≤ 20 MB.",
                zhHans: "尺寸：接近正方形、角色居中，所有状态用同样大小的画布。静态图会缩放到长边 512px；单个文件 ≤ 20MB。"),
            L10n.text(
                "Background: transparent PNG works best. For a white or flat background, turn on Remove a solid background before importing.",
                zhHans: "背景：透明 PNG 效果最好；白底或纯色底的图，导入前打开「上传时自动去除纯色背景」。"),
            L10n.text(
                "Frames: 2–12 images per state are plenty; set the speed with Frame rate (frames per second) after importing.",
                zhHans: "帧动画：每个状态 2–12 帧足够；导入后可用「帧率」调整播放速度（每秒帧数）。"),
            L10n.text(
                "Your files are copied into the app; the original folder is never changed.",
                zhHans: "导入会复制一份到应用里，原文件夹不会被修改。"),
        ]
    }
}
