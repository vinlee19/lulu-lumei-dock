import AppKit
import CoreGraphics
import Foundation

/// 一次性资产预处理:从四角连通区域 flood-fill 抠掉"外圈纯色背景",
/// 保留内部白色(眼睛/床品)。把模切贴纸转成透明浮动角色。
/// 用法:`eureka --prep-mascot-assets <srcDir> <dstDir>`
enum MascotAssetPrep {
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
}
