import AppKit
import SwiftUI

/// 应用图标：黑色灵动岛胶囊 + 青色运行点 + 金色"尤里卡"火花。
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

/// 四角火花（凹边四芒星）
struct SparkleShape: Shape {
    /// 凹度：越小越尖锐
    var concavity: CGFloat = 0.18

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let inner = radius * concavity
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addQuadCurve(
            to: CGPoint(x: center.x + radius, y: center.y),
            control: CGPoint(x: center.x + inner, y: center.y - inner))
        path.addQuadCurve(
            to: CGPoint(x: center.x, y: center.y + radius),
            control: CGPoint(x: center.x + inner, y: center.y + inner))
        path.addQuadCurve(
            to: CGPoint(x: center.x - radius, y: center.y),
            control: CGPoint(x: center.x - inner, y: center.y + inner))
        path.addQuadCurve(
            to: CGPoint(x: center.x, y: center.y - radius),
            control: CGPoint(x: center.x - inner, y: center.y - inner))
        path.closeSubpath()
        return path
    }
}

/// 1024×1024 母版。遵循 macOS 图标网格：
/// 可见圆角方块 824px 居中，四周透明留白（阴影画在留白里）。
struct AppIconView: View {
    private let canvas: CGFloat = 1024
    private let plate: CGFloat = 824

    var body: some View {
        ZStack {
            // 底板：深空蓝紫渐变 + 左上隐约高光
            RoundedRectangle(cornerRadius: plate * 0.2237, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.47, green: 0.42, blue: 1.0),
                            Color(red: 0.26, green: 0.20, blue: 0.78),
                            Color(red: 0.07, green: 0.06, blue: 0.24),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: plate * 0.2237, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.35), .white.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom),
                            lineWidth: 6
                        )
                )
                .frame(width: plate, height: plate)
                .shadow(color: .black.opacity(0.35), radius: 28, y: 14)

            // 火花的背景辉光
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.84, blue: 0.25).opacity(0.5),
                            Color(red: 0.55, green: 0.45, blue: 1.0).opacity(0.18),
                            .clear,
                        ],
                        center: .center, startRadius: 0, endRadius: 330
                    )
                )
                .frame(width: 660, height: 660)
                .offset(x: 86, y: 0)

            // 灵动岛胶囊
            Capsule(style: .continuous)
                .fill(.black)
                .frame(width: 600, height: 250)
                .shadow(color: .black.opacity(0.55), radius: 36, y: 20)
                .overlay {
                    HStack(spacing: 0) {
                        // 运行中的青色呼吸点
                        Circle()
                            .fill(Color(red: 0.25, green: 0.85, blue: 1.0))
                            .frame(width: 58, height: 58)
                            .shadow(color: Color(red: 0.25, green: 0.85, blue: 1.0).opacity(0.9),
                                    radius: 26)
                            .frame(maxWidth: .infinity)

                        // 尤里卡火花
                        SparkleShape()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 1.0, green: 0.92, blue: 0.55),
                                        Color(red: 1.0, green: 0.72, blue: 0.10),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .frame(width: 188, height: 188)
                            .shadow(color: Color(red: 1.0, green: 0.78, blue: 0.2).opacity(0.85),
                                    radius: 34)
                            .overlay(
                                // 小伴星
                                SparkleShape()
                                    .fill(Color.white.opacity(0.95))
                                    .frame(width: 44, height: 44)
                                    .offset(x: 78, y: -64)
                            )
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 64)
                }
        }
        .frame(width: canvas, height: canvas)
    }
}
