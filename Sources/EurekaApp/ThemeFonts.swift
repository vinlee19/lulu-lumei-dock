import CoreText
import SwiftUI

/// brutal 主题字体：Space Grotesk（正文）/ Space Mono（数字与等宽）。
/// 字体文件随资源包分发（Resources/Fonts/，OFL 协议），启动时注册进进程字体表。
/// 注册失败一律回退系统字体 —— 开发态字体缺失只降观感、不崩。
enum ThemeFonts {
    /// 全部字体注册成功才为 true；false 时 grotesk/mono 回退系统字体
    static private(set) var available = false

    private static let fileNames = [
        "SpaceGrotesk-Regular.ttf",
        "SpaceGrotesk-Medium.ttf",
        "SpaceGrotesk-Bold.ttf",
        "SpaceMono-Regular.ttf",
        "SpaceMono-Bold.ttf",
    ]

    /// 注册随包字体。须在首帧 UI 渲染前调用（AppDelegate 启动 / PreviewRenderer 入口）。
    /// 幂等：重复调用直接返回（.process 作用域注册一次即可）。
    static func register() {
        guard !available else { return }
        guard let fontsDir = AppResources.bundle.resourceURL?
            .appendingPathComponent("Fonts", isDirectory: true) else { return }
        var allOK = true
        for name in fileNames {
            let url = fontsDir.appendingPathComponent(name)
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                allOK = false
            }
        }
        available = allOK
    }

    /// Space Grotesk。weight 映射：medium → Medium；semibold 及以上 → Bold；其余 → Regular。
    static func grotesk(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard available else { return .system(size: size, weight: weight) }
        if weight == .medium {
            return .custom("SpaceGrotesk-Medium", size: size)
        }
        if weight == .semibold || weight == .bold || weight == .heavy || weight == .black {
            return .custom("SpaceGrotesk-Bold", size: size)
        }
        return .custom("SpaceGrotesk-Regular", size: size)
    }

    /// Space Mono。weight 映射：semibold 及以上 → Bold；其余 → Regular。
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard available else { return .system(size: size, weight: weight, design: .monospaced) }
        if weight == .semibold || weight == .bold || weight == .heavy || weight == .black {
            return .custom("SpaceMono-Bold", size: size)
        }
        return .custom("SpaceMono-Regular", size: size)
    }
}
