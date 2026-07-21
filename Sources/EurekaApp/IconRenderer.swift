import AppKit
import SwiftUI

/// 应用图标：靛紫渐变圆角方 + 金色「Lu」抽象字母组（黄金比例构造），呼应 lulu-lumei-dock 的紫金品牌色（Theme.brand / Theme.gold 同源）。
/// 用 SwiftUI 离屏渲染 1024px 母版（Scripts/make-icns.sh 据此生成 .icns）。
@MainActor
enum IconRenderer {
    static func render(to path: String) {
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = 1
        guard
            let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            print("图标渲染失败")
            exit(1)
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try png.write(to: url)
            print("已渲染 \(path)")
        } catch {
            print("写入失败: \(error)")
            exit(1)
        }
    }
}

/// 1024×1024 母版。遵循 macOS 图标网格：可见圆角方块 824px 居中，四周透明留白（阴影画在留白里）。
/// 靛紫渐变圆角方（锚定 Theme.brand 靛紫）+ 金色「Lu」抽象字母组（锚定 Theme.gold，黄金比例构造）。
struct AppIconView: View {
    private let canvas: CGFloat = 1024
    private let plate: CGFloat = 824
    /// 字母组字高（L 竖臂）；笔画粗 = H/φ³
    private let glyphHeight: CGFloat = 430
    private static let phi: CGFloat = 1.6180339

    var body: some View {
        ZStack {
            // 底板：靛紫渐变（左上亮紫 → 右下深紫）+ 左上高光描边 + 投影
            RoundedRectangle(cornerRadius: plate * 0.2237, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.55, green: 0.55, blue: 0.96),
                            Color(red: 0.36, green: 0.36, blue: 0.89),
                            Color(red: 0.16, green: 0.13, blue: 0.45),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: plate * 0.2237, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.4), .white.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom),
                            lineWidth: 6
                        )
                )
                .frame(width: plate, height: plate)
                .shadow(color: .black.opacity(0.32), radius: 28, y: 14)

            // 中心暖金柔光，托起金色字母
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 1.0, green: 0.9, blue: 0.6).opacity(0.18), .clear],
                        center: .center, startRadius: 0, endRadius: 300))
                .frame(width: 640, height: 640)

            // 「Lu」抽象字母组（圆头笔画，黄金比例）：金色渐变（亮金 → 琥珀）
            LuluMark()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.98, green: 0.87, blue: 0.55),
                            Color(red: 0.89, green: 0.74, blue: 0.38),
                            Color(red: 0.76, green: 0.58, blue: 0.18),
                        ],
                        startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(
                        lineWidth: glyphHeight / (Self.phi * Self.phi * Self.phi),
                        lineCap: .round, lineJoin: .round)
                )
                .frame(width: plate, height: glyphHeight)
                .shadow(color: Color(red: 0.10, green: 0.07, blue: 0.30).opacity(0.45),
                        radius: 10, y: 8)
        }
        .frame(width: canvas, height: canvas)
    }
}

/// 「Lu」抽象字母组：大写 L + 小写 u，笔画/长度/字高全部由黄金比 φ 推导。
/// L 竖臂 = 字高 H；L 底脚 = H/φ；u 字高 = H/φ；u 宽 = H/φ²；笔画粗 = H/φ³。
struct LuluMark: Shape {
    func path(in rect: CGRect) -> Path {
        let phi: CGFloat = 1.6180339
        let H = rect.height
        let t = H / (phi * phi * phi)           // 笔画粗细
        let foot = H / phi                       // L 底脚长
        let uH = H / phi                         // u 字高
        let uW = H / (phi * phi)                 // u 宽
        let gap = t                              // L 与 u 间距
        // 组合自然宽度（含两端圆头半径 t/2）→ 用于在 rect 内水平居中
        let groupW = foot + gap + uW + t
        let x0 = rect.midX - groupW / 2 + t / 2  // L 竖臂中线 x
        let topY = rect.midY - H / 2 + t / 2     // L 顶
        let baseY = rect.midY + H / 2 - t / 2    // 基线（L 底脚 / u 底 的中线）

        var path = Path()
        // 大写 L：竖臂 + 底脚
        path.move(to: CGPoint(x: x0, y: topY))
        path.addLine(to: CGPoint(x: x0, y: baseY))
        path.addLine(to: CGPoint(x: x0 + foot, y: baseY))

        // 小写 u：左竖 + 底半圆 + 右竖（圆头）
        let uLx = x0 + foot + gap                // u 左竖中线
        let uRx = uLx + uW                        // u 右竖中线
        let r = uW / 2                            // 底弧半径（中线）
        let uTopY = baseY - uH
        path.move(to: CGPoint(x: uLx, y: uTopY))
        path.addLine(to: CGPoint(x: uLx, y: baseY - r))
        path.addArc(
            center: CGPoint(x: uLx + r, y: baseY - r), radius: r,
            startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        path.addLine(to: CGPoint(x: uRx, y: uTopY))
        return path
    }
}
