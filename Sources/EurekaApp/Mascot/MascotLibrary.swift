import AppKit
import EurekaKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension Notification.Name {
    /// 某个动画包的文件在界面里被改动（换图 / 改名）。object = 包 id
    static let eurekaMascotPackChanged = Notification.Name("eureka.mascotPackChanged")
}

enum MascotImportError: LocalizedError {
    case unreadable
    case tooLarge
    case notAnImage
    case writeFailed
    case notEditable

    var errorDescription: String? {
        switch self {
        case .unreadable: return "无法读取所选文件"
        case .tooLarge: return "图片超过 \(MascotImageImporter.maxFileBytes / 1_048_576)MB，请换一张小一点的"
        case .notAnImage: return "所选文件不是可识别的图片"
        case .writeFailed: return "保存图片失败"
        case .notEditable: return "这个形象不是在界面上传的，请到动画包文件夹里手动修改"
        }
    }
}

/// 把用户选的图片转成包内文件：静态图缩到长边 ≤ 512px 存 PNG（可选抠掉外圈纯色背景）；
/// 多帧 GIF / APNG 原样复制以保留动画。源文件只读不改。
enum MascotImageImporter {
    static let maxFileBytes = 20 * 1_024 * 1_024
    static let maxPixelEdge = 512
    static let allowedTypes: [UTType] = [.png, .jpeg, .gif, .heic, .tiff, .webP, .bmp]

    /// 导入一张图到包目录，返回写入的文件名
    static func importImage(
        from source: URL, into dir: URL, state: MascotState, removeBackground: Bool
    ) throws -> String {
        let values = try? source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true, let size = values?.fileSize else {
            throw MascotImportError.unreadable
        }
        guard size <= maxFileBytes else { throw MascotImportError.tooLarge }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0
        else { throw MascotImportError.notAnImage }

        let stamp = Int(Date().timeIntervalSince1970 * 1_000)
        let type = CGImageSourceGetType(imageSource).map { $0 as String }

        // 动图：保留原文件（重编码会丢帧时序），渲染层用 NSImageView 原生播放。
        if CGImageSourceGetCount(imageSource) > 1,
           type == UTType.gif.identifier || type == UTType.png.identifier {
            let ext = type == UTType.gif.identifier ? "gif" : "apng"
            let name = MascotUploadNaming.imageFileName(state: state, stamp: stamp, ext: ext)
            do {
                try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(name))
            } catch {
                throw MascotImportError.writeFailed
            }
            return name
        }

        // 缩略图接口顺带处理 EXIF 方向，且不会放大小图。
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelEdge,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(
            imageSource, 0, options as CFDictionary)
        else { throw MascotImportError.notAnImage }
        // 已经是透明底的图不再抠，避免把贴边的深色描边当背景吃掉。
        if removeBackground, !MascotAssetPrep.hasTransparentCorners(image),
           let cut = MascotAssetPrep.removeBackground(image) {
            image = cut
        }
        let name = MascotUploadNaming.imageFileName(state: state, stamp: stamp, ext: "png")
        guard writePNG(image, to: dir.appendingPathComponent(name)) else {
            throw MascotImportError.writeFailed
        }
        return name
    }

    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}

/// 设置页「桌面伙伴」的数据源：列出可选形象、生成缩略图，并负责上传包的增删改。
/// 只改界面上传生成的包（manifest 带 origin=upload）；手写的动画包与预设一律只读。
/// 只由设置页在主线程调用；不标 @MainActor，便于直接作为 @StateObject 初始值。
final class MascotLibrary: ObservableObject {
    /// 正在编辑的上传包
    struct Editing: Equatable {
        var id: String
        var name: String
        /// 单独配置了图片的状态 → 文件名
        var files: [MascotState: String]
        /// 每个可编辑状态实际显示的图（含沿回退链复用的）
        var images: [MascotState: NSImage]
    }

    @Published private(set) var packs: [MascotPackInfo] = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var editing: Editing?
    @Published var lastError: String?

    var presetPacks: [MascotPackInfo] { packs.filter { $0.kind != .custom } }
    var customPacks: [MascotPackInfo] { packs.filter { $0.kind == .custom } }

    func refresh() {
        packs = MascotPackLoader.availablePacks()
        var result: [String: NSImage] = [:]
        for info in packs {
            let pack = MascotPackLoader.load(packID: info.id)
            let animation = pack.animation(for: .idle)
                ?? pack.variants(for: .idle).first?.animation
            if let animation, let image = Self.firstFrame(of: animation) {
                result[info.id] = image
            }
        }
        thumbnails = result
    }

    /// 切换选中项时调用：上传包进入可编辑状态，其余包清空编辑区。
    func select(packID: String) {
        guard let dir = try? editableDirectory(packID),
              let data = MascotPackLoader.readManifest(in: dir)
        else {
            editing = nil
            return
        }
        let files = MascotManifestEditor.stateFiles(data)
        var images: [MascotState: NSImage] = [:]
        for state in MascotManifestEditor.editableStates {
            guard let source = MascotManifestEditor.effectiveSource(for: state, files: files),
                  let file = files[source],
                  let image = NSImage(contentsOf: dir.appendingPathComponent(file))
            else { continue }
            images[state] = image
        }
        editing = Editing(
            id: packID,
            name: MascotManifestEditor.name(data) ?? packID,
            files: files,
            images: images)
    }

    /// 用一张图新建形象，成功返回新包 id
    func createPack(from source: URL, removeBackground: Bool) -> String? {
        let fm = FileManager.default
        let root = MascotPackLoader.customRoot()
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let existing = Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            let dirName = MascotUploadNaming.directoryName(now: Date(), existing: existing)
            let dir = root.appendingPathComponent(dirName, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: false)
            do {
                let file = try MascotImageImporter.importImage(
                    from: source, into: dir, state: .idle, removeBackground: removeBackground)
                let manifest = MascotManifestEditor.makeUploadManifest(
                    name: MascotUploadNaming.displayName(fromFileName: source.lastPathComponent),
                    baseFile: file)
                try manifest.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
            } catch {
                // 半成品目录不留：否则列表里会出现一个无效包
                try? fm.removeItem(at: dir)
                throw error
            }
            lastError = nil
            refresh()
            return MascotPackRef.custom(dirName).id
        } catch {
            lastError = Self.message(for: error)
            return nil
        }
    }

    /// 给某状态单独换图（idle 即替换基础形象）
    func setImage(for state: MascotState, packID: String, from source: URL, removeBackground: Bool) {
        perform(packID: packID) { dir, data in
            let file = try MascotImageImporter.importImage(
                from: source, into: dir, state: state, removeBackground: removeBackground)
            let old = MascotManifestEditor.stateFiles(data)[state]
            let updated = try MascotManifestEditor.settingState(state, file: file, in: data)
            return (updated, old.map { [$0] } ?? [])
        }
    }

    /// 清除某状态的单独配图，回到沿回退链复用
    func resetImage(for state: MascotState, packID: String) {
        perform(packID: packID) { _, data in
            let old = MascotManifestEditor.stateFiles(data)[state]
            let updated = try MascotManifestEditor.settingState(state, file: nil, in: data)
            return (updated, old.map { [$0] } ?? [])
        }
    }

    func rename(packID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform(packID: packID) { _, data in
            let updated = try MascotManifestEditor.renaming(to: String(trimmed.prefix(24)), in: data)
            return (updated, [])
        }
    }

    /// 删除上传包：整个目录移到废纸篓（可找回），不直接抹掉。
    func delete(packID: String) {
        do {
            let dir = try editableDirectory(packID)
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
            lastError = nil
        } catch {
            lastError = Self.message(for: error)
        }
        if editing?.id == packID { editing = nil }
        refresh()
    }

    // MARK: - 内部

    /// 读 manifest → 改 → 原子写回，再清理不再被引用的旧图并通知桌宠重载。
    private func perform(
        packID: String,
        _ change: (URL, Data) throws -> (manifest: Data, replacedFiles: [String])
    ) {
        do {
            let dir = try editableDirectory(packID)
            guard let data = MascotPackLoader.readManifest(in: dir) else {
                throw MascotImportError.notEditable
            }
            let (updated, replaced) = try change(dir, data)
            try updated.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
            let stillUsed = Set(MascotManifestEditor.stateFiles(updated).values)
            // 只删包目录里的单层文件名，manifest 被手改成 ../ 之类时不越界
            let stale = replaced.filter {
                !stillUsed.contains($0) && MascotPackRef.isSafeDirectoryName($0)
            }
            for file in stale {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            }
            lastError = nil
            NotificationCenter.default.post(name: .eurekaMascotPackChanged, object: packID)
        } catch {
            lastError = Self.message(for: error)
        }
        refresh()
        select(packID: packID)
    }

    /// 只有用户目录下、manifest 标了 origin=upload 的包可在界面修改
    private func editableDirectory(_ packID: String) throws -> URL {
        guard case .custom = MascotPackRef(id: packID),
              let dir = MascotPackLoader.directory(for: MascotPackRef(id: packID)),
              let data = MascotPackLoader.readManifest(in: dir),
              MascotManifestEditor.isUpload(data)
        else { throw MascotImportError.notEditable }
        return dir
    }

    private static func firstFrame(of animation: MascotAnimation) -> NSImage? {
        switch animation {
        case .frames(let urls, _):
            return urls.first.flatMap { NSImage(contentsOf: $0) }
        case .animatedImage(let url):
            return NSImage(contentsOf: url)
        case .spriteSequence(let sheet, let cells, _):
            return MascotSpriteCache.frames(sheet: sheet, cells: Array(cells.prefix(1))).first
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
