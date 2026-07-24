import AppKit
import EurekaKit
import SwiftUI

/// 桌面吉祥物根视图:圆角贴纸卡 + 气泡;随状态切动画。
struct MascotRootView: View {
    @ObservedObject var viewModel: MascotViewModel
    var onHide: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    private let cardSize: CGFloat = 132

    var body: some View {
        VStack(spacing: 5) {
            Spacer(minLength: 0)
            if let bubble = viewModel.bubble {
                SpeechBubble(text: bubble)
                    .transition(.opacity.combined(with: .scale(scale: 0.7, anchor: .bottom)))
            }
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(8)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: viewModel.bubble)
        .animation(.easeInOut(duration: 0.25), value: viewModel.state)
        .contextMenu {
            Button("打开设置") { onOpenSettings() }
            Button("隐藏吉祥物") { onHide() }
        }
    }

    // 透明浮动角色(无白卡)+ 落地软阴影 + 状态切换大动作过场 + 点击俏皮反应
    private var card: some View {
        MotionContainer(state: viewModel.state, profile: viewModel.motionProfile) {
            mascot
                .id("\(viewModel.variantID)-\(viewModel.lookDirection ?? -1)")
                .transition(.opacity)
        }
            .frame(width: cardSize, height: cardSize)
            .animation(.easeOut(duration: 0.16), value: viewModel.variantID)
            .animation(.easeOut(duration: 0.12), value: viewModel.lookDirection)
            .phaseAnimator([0, 1, 2, 3], trigger: viewModel.transitionTick) { content, phase in
                let pose = viewModel.transitionStyle.pose(phase: phase)
                content
                    .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: .bottom)
                    .rotation3DEffect(.degrees(pose.flip), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
                    .rotationEffect(.degrees(pose.rotation))
                    .offset(y: pose.yOffset)
            } animation: { phase in
                viewModel.transitionStyle.animation(toPhase: phase)
            }
            .shadow(color: .black.opacity(0.28), radius: 7, y: 3)
            .contentShape(Rectangle())
            .onTapGesture { viewModel.poke() }
            .overlay(alignment: .bottom) {
                if let caption = viewModel.caption {
                    ArtTextView(text: caption, state: viewModel.state, maxWidth: cardSize - 8)
                        .padding(.bottom, 2)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .id(caption)
                }
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.6), value: viewModel.caption)
    }

    @ViewBuilder
    private var mascot: some View {
        switch viewModel.animation {
        case .frames(let urls, let fps):
            FrameAnimator(urls: urls, fps: fps)
        case .animatedImage(let url):
            AnimatedImageView(url: url)
        case .spriteSequence(let url, let cells, let fps):
            SpriteSequenceAnimator(url: url, cells: cells, fps: fps)
        case .none:
            Image(systemName: "tortoise.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
        }
    }
}

/// 从 8×11 v2 精灵图裁出任意帧序列。裁切只做一次，播放期间复用 NSImage。
private struct SpriteSequenceAnimator: View {
    let url: URL
    let cells: [MascotSpriteCell]
    let fps: Double
    @State private var images: [NSImage] = []

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1.0 / max(0.1, fps))) { context in
            let idx = images.isEmpty
                ? 0
                : Int(context.date.timeIntervalSinceReferenceDate * fps) % images.count
            Group {
                if images.indices.contains(idx) {
                    Image(nsImage: images[idx])
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Color.clear
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: url) { _, _ in reload() }
        .onChange(of: cells) { _, _ in reload() }
    }

    private func reload() {
        images = MascotSpriteCache.frames(url: url, cells: cells)
    }
}

/// 鼠标扫过 16 向视线时会频繁换格；缓存整张图和裁切结果，避免反复从磁盘解码 4MB 图集。
private enum MascotSpriteCache {
    private static let atlasCache = NSCache<NSURL, NSImage>()
    private static let frameCache = NSCache<NSString, NSImage>()

    static func frames(url: URL, cells: [MascotSpriteCell]) -> [NSImage] {
        let source: NSImage
        if let cached = atlasCache.object(forKey: url as NSURL) {
            source = cached
        } else if let loaded = NSImage(contentsOf: url) {
            atlasCache.setObject(loaded, forKey: url as NSURL)
            source = loaded
        } else {
            return []
        }
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width >= 8, cg.height >= 11
        else { return [] }

        let cellWidth = cg.width / 8
        let cellHeight = cg.height / 11
        return cells.compactMap { cell in
            guard (0..<11).contains(cell.row), (0..<8).contains(cell.column) else { return nil }
            let key = "\(url.path)#\(cell.row)#\(cell.column)" as NSString
            if let cached = frameCache.object(forKey: key) { return cached }
            guard let frame = cg.cropping(to: CGRect(
                x: cell.column * cellWidth,
                y: cell.row * cellHeight,
                width: cellWidth,
                height: cellHeight))
            else { return nil }
            let image = NSImage(
                cgImage: frame,
                size: NSSize(width: cellWidth, height: cellHeight))
            frameCache.setObject(image, forKey: key)
            return image
        }
    }
}

/// PNG 帧按 fps 循环(全彩,避免 GIF 色带)
private struct FrameAnimator: View {
    let urls: [URL]
    let fps: Double
    @State private var images: [NSImage] = []

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1.0 / max(0.1, fps))) { context in
            let idx = images.isEmpty
                ? 0
                : Int(context.date.timeIntervalSinceReferenceDate * fps) % images.count
            Group {
                if images.indices.contains(idx) {
                    Image(nsImage: images[idx])
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    Color.clear
                }
            }
        }
        .onAppear { reload(urls) }
        .onChange(of: urls) { _, new in reload(new) }
    }

    private func reload(_ urls: [URL]) {
        images = urls.compactMap { NSImage(contentsOf: $0) }
    }
}

/// GIF/APNG 用 NSImageView 原生播放
private struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.image = NSImage(contentsOf: url)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = NSImage(contentsOf: url)
        view.animates = true
    }
}

/// 给静态贴纸叠加"肢体语言":每状态不同的呼吸/抖动/小跳/摇摆,~30fps。
private struct MotionContainer<Content: View>: View {
    let state: MascotState
    let profile: MascotMotionProfile
    @ViewBuilder var content: () -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let m = MascotMotion.transform(
                for: state, profile: profile,
                t: context.date.timeIntervalSinceReferenceDate)
            content()
                .scaleEffect(m.scale, anchor: .bottom)
                .rotationEffect(m.rotation, anchor: .bottom)
                .offset(m.offset)
        }
    }
}

/// 艺术字的动作风格
private enum ArtMotion { case bob, pulse, wobble, shake, sway, bounce, waveRainbow }

/// 每状态一套艺术字风格(配色 + 动作),让文字"变换各种风格"。
private struct ArtTextStyle {
    var colors: [Color]
    var motion: ArtMotion

    static func style(for state: MascotState) -> ArtTextStyle {
        func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        switch state {
        case .working: return .init(colors: [c(0.95, 0.63, 0.24), c(0.95, 0.47, 0.62)], motion: .bob)
        case .idle:    return .init(colors: [c(0.24, 0.71, 0.75), c(0.44, 0.76, 0.95)], motion: .pulse)
        case .waiting: return .init(colors: [c(0.63, 0.44, 0.95), c(0.95, 0.45, 0.78)], motion: .wobble)
        case .success: return .init(colors: [], motion: .waveRainbow)
        case .error:   return .init(colors: [c(0.95, 0.36, 0.30), c(0.95, 0.63, 0.24)], motion: .shake)
        case .sleeping: return .init(colors: [c(0.42, 0.48, 0.88), c(0.60, 0.63, 0.78)], motion: .pulse)
        case .relax:   return .init(colors: [c(0.31, 0.75, 0.55), c(0.24, 0.73, 0.69)], motion: .sway)
        case .night:   return .init(colors: [c(0.48, 0.42, 0.88), c(0.69, 0.48, 0.88)], motion: .pulse)
        case .poke, .wake: return .init(colors: [c(0.95, 0.47, 0.62), c(0.95, 0.78, 0.30)], motion: .bounce)
        }
    }
}

/// 贴纸上的动态英文艺术字:白描边 + 倾斜,配色与动作随状态切换(success 用彩虹逐字波浪)。
struct ArtTextView: View {
    let text: String
    let state: MascotState
    var maxWidth: CGFloat = 118

    private var style: ArtTextStyle { ArtTextStyle.style(for: state) }
    private var font: Font { .system(size: 22, weight: .black, design: .rounded) }
    private let stroke: CGFloat = 1.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Group {
                if style.motion == .waveRainbow {
                    rainbowLetters(t: t)
                } else {
                    word(t: t)
                }
            }
            .rotationEffect(.degrees(-6))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
    }

    // MARK: 整词(渐变流光 + 各自动作)

    private func word(t: Double) -> some View {
        let motion = wordMotion(t: t)
        let phase = t.truncatingRemainder(dividingBy: 2.6) / 2.6
        return ZStack {
            outlineLayer(text)
            glyph(text, nil)
                .foregroundStyle(LinearGradient(
                    colors: [style.colors[0], style.colors[1], style.colors[0]],
                    startPoint: UnitPoint(x: phase - 1, y: 0.5),
                    endPoint: UnitPoint(x: phase + 1, y: 0.5)))
        }
        .scaleEffect(motion.scale)
        .rotationEffect(.degrees(motion.rot))
        .offset(y: motion.dy)
    }

    private func wordMotion(t: Double) -> (scale: CGFloat, rot: Double, dy: CGFloat) {
        func wave(_ p: Double) -> Double { sin(t * 2 * .pi / p) }
        switch style.motion {
        case .pulse:  return (1 + 0.05 * wave(1.4), 0, 0)
        case .wobble: return (1, 5 * wave(0.5), 0)
        case .shake:  return (1, 4 * wave(0.12), 0)
        case .sway:   return (1, 4 * wave(2.0), 0)
        case .bounce: return (1, 0, -5 * abs(wave(0.45)))
        default:      return (1, 0, -2 * wave(1.6))  // bob
        }
    }

    // MARK: success 彩虹逐字波浪

    private func rainbowLetters(t: Double) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, char in
                let dy = sin(t * 4 + Double(index) * 0.6) * 4
                let hue = (t * 0.15 + Double(index) * 0.09).truncatingRemainder(dividingBy: 1)
                ZStack {
                    outlineLayer(String(char))
                    glyph(String(char), Color(hue: hue, saturation: 0.9, brightness: 1))
                }
                .offset(y: dy)
            }
        }
    }

    // MARK: 字形 + 描边

    private func outlineLayer(_ string: String) -> some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) / 8 * 2 * .pi
                glyph(string, .white)
                    .offset(x: cos(angle) * stroke, y: sin(angle) * stroke)
            }
        }
    }

    @ViewBuilder private func glyph(_ string: String, _ color: Color?) -> some View {
        let base = Text(string)
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: maxWidth)
        if let color { base.foregroundStyle(color) } else { base }
    }
}

enum MascotMotion {
    /// 返回某状态在时刻 t 的形变(缩放/旋转/位移),幅度刻意克制以免廉价感。
    static func transform(
        for state: MascotState, profile: MascotMotionProfile = .stateDefault, t: Double
    ) -> (scale: CGSize, rotation: Angle, offset: CGSize) {
        func wave(_ period: Double) -> Double { sin(t * 2 * .pi / period) }
        let none = CGSize(width: 1, height: 1)
        switch profile {
        case .gentle:
            let b = wave(3.4)
            return (CGSize(width: 1, height: 1 + 0.012 * b), .degrees(0.5 * b),
                    CGSize(width: 0, height: -1.2 * b))
        case .focus:
            let s = wave(0.28)
            return (none, .degrees(0.35 * s), CGSize(width: 0.45 * s, height: 0))
        case .curious:
            let s = wave(2.6)
            return (none, .degrees(1.7 * s), CGSize(width: 0, height: -1.2 * abs(s)))
        case .nudge:
            let b = abs(wave(0.72))
            return (none, .degrees(1.4 * wave(0.72)), CGSize(width: 0, height: -3 * b))
        case .celebrate:
            let b = abs(wave(0.46))
            return (CGSize(width: 1 + 0.018 * b, height: 1 + 0.025 * b), .zero,
                    CGSize(width: 0, height: -5 * b))
        case .droop:
            return (none, .degrees(0.8 * wave(0.8)), CGSize(width: 0, height: 1.5))
        case .sleep:
            let b = wave(4.2)
            return (CGSize(width: 1, height: 1 + 0.018 * b), .zero,
                    CGSize(width: 0, height: -0.8 * b))
        case .sway:
            return (none, .degrees(1.8 * wave(3.8)), .zero)
        case .still:
            return (none, .zero, .zero)
        case .stateDefault:
            break
        }
        switch state {
        case .idle:  // 慢呼吸 + 轻浮
            let b = wave(3.2)
            return (CGSize(width: 1, height: 1 + 0.015 * b), .zero, CGSize(width: 0, height: -1.5 * b))
        case .working:  // 敲键盘的细微抖动
            let s = wave(0.22)
            return (none, .degrees(0.6 * s), CGSize(width: 0.8 * s, height: 0))
        case .waiting:  // 期待小跳 + 摇
            let bob = abs(wave(0.6))
            return (none, .degrees(2 * wave(0.6)), CGSize(width: 0, height: -5 * bob))
        case .success:  // 开心蹦
            let bob = abs(wave(0.4))
            return (CGSize(width: 1 + 0.03 * bob, height: 1 + 0.03 * bob), .zero,
                    CGSize(width: 0, height: -8 * bob))
        case .error:  // 耷拉 + 轻微摇头
            return (none, .degrees(1.4 * wave(0.5)), CGSize(width: 0, height: 2))
        case .sleeping:  // 深呼吸
            let b = wave(4.0)
            return (CGSize(width: 1, height: 1 + 0.025 * b), .zero, CGSize(width: 0, height: -1 * b))
        case .relax:  // 轻轻摇摆
            return (none, .degrees(2.5 * wave(3.4)), .zero)
        case .night:  // 打盹点头
            let nod = wave(3.0)
            return (none, .degrees(2 * nod), CGSize(width: 0, height: -1.5 * nod))
        case .poke, .wake:
            return (none, .zero, .zero)
        }
    }
}

private struct SpeechBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 150)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.black.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
    }
}
