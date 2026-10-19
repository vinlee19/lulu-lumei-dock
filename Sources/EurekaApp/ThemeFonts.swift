import CoreText
import SwiftUI

/// brutal theme fonts: Space Grotesk (body) / Space Mono (numbers and monospace). Font files ship
/// in the resource bundle (Resources/Fonts/, OFL license) and are registered into the process font
/// table at launch. Any registration failure falls back to the system font -- missing fonts in dev
/// only degrade the look, never crash.
enum ThemeFonts {
    /// true only if every font registered successfully; when false, grotesk/mono fall back to the
    /// system font
    static private(set) var available = false

    private static let fileNames = [
        "SpaceGrotesk-Regular.ttf",
        "SpaceGrotesk-Medium.ttf",
        "SpaceGrotesk-Bold.ttf",
        "SpaceMono-Regular.ttf",
        "SpaceMono-Bold.ttf",
    ]

    /// Registers the bundled fonts. Must be called before the first UI frame renders (AppDelegate
    /// launch / PreviewRenderer entry). Idempotent: repeated calls return immediately (registering
    /// once in .process scope is enough).
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

    /// Space Grotesk. Weight mapping: medium → Medium; semibold and above → Bold; others → Regular.
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

    /// Space Mono. Weight mapping: semibold and above → Bold; others → Regular.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard available else { return .system(size: size, weight: weight, design: .monospaced) }
        if weight == .semibold || weight == .bold || weight == .heavy || weight == .black {
            return .custom("SpaceMono-Bold", size: size)
        }
        return .custom("SpaceMono-Regular", size: size)
    }
}
