import AppKit
import EurekaKit
import SwiftUI

/// App icon: indigo-violet gradient rounded square + a gold abstract "Lu" letter group
/// (golden-ratio construction), echoing lulu-lumei-dock's violet-gold brand colors (same source as
/// Theme.brand / Theme.gold). Renders the 1024px master offscreen with SwiftUI
/// (Scripts/make-icns.sh builds the .icns from it).
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
            print(L10n.text("Icon rendering failed", zhHans: "图标渲染失败"))
            exit(1)
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try png.write(to: url)
            print(L10n.format("Rendered %@", zhHans: "已渲染 %@", String(path)))
        } catch {
            print(L10n.format("Write failed: %@", zhHans: "写入失败: %@", String(describing: error)))
            exit(1)
        }
    }
}

/// 1024×1024 master. Follows the macOS icon grid: the visible rounded square is 824px centered,
/// with transparent margin around it (the shadow is drawn in the margin). Indigo-violet gradient
/// rounded square (anchored on Theme.brand indigo) + gold abstract "Lu" letter group (anchored on
/// Theme.gold, golden-ratio construction).
struct AppIconView: View {
    private let canvas: CGFloat = 1024
    private let plate: CGFloat = 824
    /// Letter-group height (the L's vertical stem); stroke width = H/φ³
    private let glyphHeight: CGFloat = 430
    private static let phi: CGFloat = 1.6180339

    var body: some View {
        ZStack {
            // Base plate: indigo-violet gradient (bright violet top-left -> deep violet
            // bottom-right) + top-left highlight stroke + drop shadow
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

            // Warm gold glow at the center, lifting the gold letters
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 1.0, green: 0.9, blue: 0.6).opacity(0.18), .clear],
                        center: .center, startRadius: 0, endRadius: 300))
                .frame(width: 640, height: 640)

            // "Lu" abstract letter group (round-capped strokes, golden ratio): gold gradient
            // (bright gold -> amber)
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

/// "Lu" abstract letter group: capital L + lowercase u, with stroke, lengths and height all derived
/// from the golden ratio φ. L stem = height H; L foot = H/φ; u height = H/φ; u width = H/φ²; stroke
/// width = H/φ³.
struct LuluMark: Shape {
    func path(in rect: CGRect) -> Path {
        let phi: CGFloat = 1.6180339
        let H = rect.height
        let t = H / (phi * phi * phi)           // stroke width
        let foot = H / phi                       // L foot length
        let uH = H / phi                         // u height
        let uW = H / (phi * phi)                 // u width
        let gap = t                              // gap between L and u
        // Natural width of the group (including the round-cap radius t/2 at both ends) -> used to
        // center it horizontally in rect
        let groupW = foot + gap + uW + t
        let x0 = rect.midX - groupW / 2 + t / 2  // x of the L stem's center line
        let topY = rect.midY - H / 2 + t / 2     // top of the L
        let baseY = rect.midY + H / 2 - t / 2    // baseline (center line of the L foot / u bottom)

        var path = Path()
        // Capital L: stem + foot
        path.move(to: CGPoint(x: x0, y: topY))
        path.addLine(to: CGPoint(x: x0, y: baseY))
        path.addLine(to: CGPoint(x: x0 + foot, y: baseY))

        // Lowercase u: left stem + bottom semicircle + right stem (round caps)
        let uLx = x0 + foot + gap                // center line of the u's left stem
        let uRx = uLx + uW                        // center line of the u's right stem
        let r = uW / 2                            // bottom arc radius (center line)
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
