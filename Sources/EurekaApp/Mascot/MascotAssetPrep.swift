import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// 一次性资产预处理:从四角连通区域 flood-fill 抠掉"外圈纯色背景",
/// 保留内部白色(眼睛/床品)。把模切贴纸转成透明浮动角色。
/// 用法:`eureka --prep-mascot-assets <srcDir> <dstDir>`
enum MascotAssetPrep {
    private static let v3SheetNames = [
        "00-idle-snack.png",
        "01-working-pair.png",
        "02-working-lumei-idea.png",
        "03-waiting-lulu.png",
        "04-success-high-five.png",
        "05-error-lumei-comforts.png",
        "06-error-lulu-encourages.png",
        "07-relax-tea.png",
        "08-sleeping-blanket.png",
        "09-night-bedtime.png",
        "10-poke-boop.png",
        "11-wake.png",
    ]

    static func run(srcDir: String, dstDir: String) {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: srcDir)
        let dst = URL(fileURLWithPath: dstDir)
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension.lowercased() == "png" {
            guard let image = NSImage(contentsOf: file),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let out = removeBackground(cg)
            else { print("跳过 \(file.lastPathComponent)"); continue }
            writePNG(out, to: dst.appendingPathComponent(file.lastPathComponent))
            print("✓ \(file.lastPathComponent)")
        }
    }

    /// 从四角 flood-fill,容差内的连通背景像素 → 透明(并清零 RGB 防白边)。
    static func removeBackground(_ image: CGImage, tolerance: Int = 72) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 4, h > 4 else { return image }
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 参考背景色 = 四角均值
        let cornerPts = [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)]
        var sr = 0, sg = 0, sb = 0
        for (x, y) in cornerPts {
            let i = (y * w + x) * 4
            sr += Int(data[i]); sg += Int(data[i + 1]); sb += Int(data[i + 2])
        }
        sr /= 4; sg /= 4; sb /= 4

        func diff(_ i: Int) -> Int {
            abs(Int(data[i]) - sr) + abs(Int(data[i + 1]) - sg) + abs(Int(data[i + 2]) - sb)
        }

        var visited = [Bool](repeating: false, count: w * h)
        var stack = [Int]()
        for (x, y) in cornerPts {
            let p = y * w + x
            if !visited[p] { visited[p] = true; stack.append(p) }
        }
        while let p = stack.popLast() {
            let i = p * 4
            guard diff(i) < tolerance else { continue }
            data[i] = 0; data[i + 1] = 0; data[i + 2] = 0; data[i + 3] = 0
            let x = p % w, y = p / w
            if x > 0 { let q = p - 1; if !visited[q] { visited[q] = true; stack.append(q) } }
            if x < w - 1 { let q = p + 1; if !visited[q] { visited[q] = true; stack.append(q) } }
            if y > 0 { let q = p - w; if !visited[q] { visited[q] = true; stack.append(q) } }
            if y < h - 1 { let q = p + w; if !visited[q] { visited[q] = true; stack.append(q) } }
        }

        // 羽化:与透明相邻、且偏背景色的半透明边缘像素降低 alpha,减白边
        var alphaCut = [(Int, UInt8)]()
        for p in 0..<(w * h) where !visited[p] {
            let i = p * 4
            guard diff(i) < tolerance * 2 else { continue }
            let x = p % w, y = p / w
            let neighborTransparent =
                (x > 0 && visited[p - 1]) || (x < w - 1 && visited[p + 1])
                || (y > 0 && visited[p - w]) || (y < h - 1 && visited[p + w])
            if neighborTransparent {
                let t = Double(diff(i)) / Double(tolerance * 2)  // 0..1
                alphaCut.append((i, UInt8(max(0, min(255, t * 255)))))
            }
        }
        for (i, a) in alphaCut { data[i + 3] = a }

        return ctx.makeImage()
    }

    static func writePNG(_ cg: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: cg)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    /// 把 12 张 2×2 透明分镜图按固定顺序打包为 4×12、每格 256px 的 v3 图集。
    /// 输入只接受源目录的直接子文件，拒绝软链接和非 PNG 文件，避免路径越界。
    static func packV3(srcDir: String, outputPath: String) throws {
        let fm = FileManager.default
        let sourceDirectory = URL(fileURLWithPath: srcDir, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw MascotAssetPrepError.invalidSourceDirectory
        }

        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        guard outputURL.pathExtension.lowercased() == "png" else {
            throw MascotAssetPrepError.invalidOutput
        }
        guard !fm.fileExists(atPath: outputURL.path) else {
            throw MascotAssetPrepError.outputAlreadyExists
        }

        let sourceImages = try v3SheetNames.map { name -> NSImage in
            let candidate = sourceDirectory.appendingPathComponent(name)
                .standardizedFileURL
            guard candidate.deletingLastPathComponent() == sourceDirectory,
                  candidate.pathExtension.lowercased() == "png"
            else {
                throw MascotAssetPrepError.unsafeSource(name)
            }
            let values = try candidate.resourceValues(forKeys: [
                .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let fileSize = values.fileSize, fileSize <= 32 * 1_024 * 1_024,
                  candidate.resolvingSymlinksInPath().deletingLastPathComponent()
                    == sourceDirectory,
                  let imageSource = CGImageSourceCreateWithURL(candidate as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(
                    imageSource, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width == height, width.isMultiple(of: 2),
                  (512...4_096).contains(width),
                  let cg = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                  cg.width == width, cg.height == height,
                  hasTransparentCorners(cg)
            else {
                throw MascotAssetPrepError.invalidSheet(name)
            }
            return NSImage(
                cgImage: cg,
                size: NSSize(width: width, height: height))
        }

        let cellSize = 256
        let atlasWidth = cellSize * 4
        let atlasHeight = cellSize * v3SheetNames.count
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: atlasWidth,
            height: atlasHeight,
            bitsPerComponent: 8,
            bytesPerRow: atlasWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw MascotAssetPrepError.cannotCreateAtlas
        }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: atlasWidth, height: atlasHeight).fill(using: .copy)
        for (row, image) in sourceImages.enumerated() {
            let halfWidth = image.size.width / 2
            let halfHeight = image.size.height / 2
            for frame in 0..<4 {
                let sourceColumn = frame % 2
                let sourceRow = frame / 2
                let sourceRect = NSRect(
                    x: CGFloat(sourceColumn) * halfWidth,
                    y: sourceRow == 0 ? halfHeight : 0,
                    width: halfWidth,
                    height: halfHeight)
                let targetRect = NSRect(
                    x: frame * cellSize,
                    y: atlasHeight - (row + 1) * cellSize,
                    width: cellSize,
                    height: cellSize)
                image.draw(
                    in: targetRect,
                    from: sourceRect,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: false,
                    hints: [.interpolation: NSImageInterpolation.high])
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let atlas = context.makeImage() else {
            throw MascotAssetPrepError.cannotCreateAtlas
        }
        let bitmap = NSBitmapImageRep(cgImage: atlas)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw MascotAssetPrepError.cannotCreateAtlas
        }
        try fm.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try png.write(to: outputURL, options: .withoutOverwriting)
        print("✓ v3 图集 \(atlasWidth)×\(atlasHeight): \(outputURL.path)")
    }

    private static func hasTransparentCorners(_ image: CGImage) -> Bool {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard bitmap.hasAlpha else { return false }
        let points = [
            NSPoint(x: 0, y: 0),
            NSPoint(x: image.width - 1, y: 0),
            NSPoint(x: 0, y: image.height - 1),
            NSPoint(x: image.width - 1, y: image.height - 1),
        ]
        return points.allSatisfy {
            (bitmap.colorAt(x: Int($0.x), y: Int($0.y))?.alphaComponent ?? 1) < 0.05
        }
    }
}

private enum MascotAssetPrepError: LocalizedError {
    case invalidSourceDirectory
    case invalidOutput
    case outputAlreadyExists
    case unsafeSource(String)
    case invalidSheet(String)
    case cannotCreateAtlas

    var errorDescription: String? {
        switch self {
        case .invalidSourceDirectory:
            "源目录不存在或不是文件夹"
        case .invalidOutput:
            "输出路径必须是 PNG 文件"
        case .outputAlreadyExists:
            "输出文件已存在，为避免误覆盖已停止"
        case .unsafeSource(let name):
            "素材路径越界或格式不受支持：\(name)"
        case .invalidSheet(let name):
            "素材必须是 512...4096px、正方形、偶数尺寸、透明四角的普通 PNG：\(name)"
        case .cannotCreateAtlas:
            "无法创建 v3 图集"
        }
    }
}
