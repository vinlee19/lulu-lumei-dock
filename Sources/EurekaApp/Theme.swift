import EurekaIngest
import EurekaInstall
import EurekaKit
import SwiftUI

/// UI style: classic = classic indigo-purple and gold (default) / brutal = Neo-Brutalism (cream
/// background, 2px ink borders, zero-blur hard shadows, Space Grotesk/Mono fonts, flat colors
/// without gradients; visual reference: raft.build's brutalist design language). The remaining
/// cases are **palette themes** (high-star color schemes from the GitHub community, official
/// palettes, MIT/Apache licensed): structure follows classic (radii/soft shadows/thin borders
/// unchanged), only colors are swapped. The user preference is switched in Settings → General and
/// stored in AppSettings.themeStyle.
enum ThemeStyle: String {
    case classic
    case brutal
    case catppuccin
    case gruvbox
    case nord
    case solarized
    case rosepine
    case onedark
    case kanagawa

    /// The current style. Read and written on the main thread only (AppSettings didSet and SwiftUI
    /// body evaluation are both on the main thread), treated the same as the other static members
    /// in this file. After a style switch the root view's .id forces a full tree rebuild that
    /// re-reads values.
    static var current: ThemeStyle = .classic

    /// Resolves a persisted / CLI-provided style id; "raft" is an old id briefly used in 0.20.x,
    /// mapped for compatibility.
    static func resolve(_ raw: String) -> ThemeStyle {
        ThemeStyle(rawValue: raw) ?? (raw == "raft" ? .brutal : .classic)
    }

    /// Whether this is a themed style (anything but classic; all colors go through each style's
    /// tokens)
    var isThemed: Bool { self != .classic }

    /// Whether this is a structural style (hard edges/flat colors/hard shadows). Palette themes
    /// return false -- structure follows classic, only colors change
    var isHardEdged: Bool { self == .brutal }
}

/// Palette theme palette (hex light / dark; structure follows classic, only colors change).
private struct ThemePalette {
    var windowBackground: (String, String)
    var surface: (String, String)
    var surfaceSecondary: (String, String)
    var surfaceTertiary: (String, String)
    var cardBorder: (String, String)
    var brand: (String, String)
    var gold: (String, String)
    var ink: (String, String)
    var onBrand: (String, String)
    var green: (String, String)
    var red: (String, String)
    var warn: (String, String)
}

/// Global design tokens: brand accent colors, semantic status colors, neutral backgrounds, spacing.
/// UI colors/spacing all come from here, so the same meaning isn't re-implemented in every view.
/// Multi-theme mechanism: tokens dispatch on ThemeStyle.current; the classic branch keeps the
/// "purple-gold" mockup's original values verbatim.
enum Theme {
    // MARK: - Palette theme table (official palette values; the dark column is each theme's official dark flavor)

    private static let palettes: [ThemeStyle: ThemePalette] = [
        // Catppuccin: Latte (light) / Mocha (dark)
        .catppuccin: ThemePalette(
            windowBackground: ("EFF1F5", "1E1E2E"), surface: ("FFFFFF", "313244"),
            surfaceSecondary: ("E6E9EF", "292C3C"), surfaceTertiary: ("DCE0E8", "181825"),
            cardBorder: ("CCD0DA", "45475A"),
            brand: ("8839EF", "CBA6F7"), gold: ("FE640B", "FAB387"),
            ink: ("4C4F69", "CDD6F4"), onBrand: ("FFFFFF", "11111B"),
            green: ("40A02B", "A6E3A1"), red: ("D20F39", "F38BA8"), warn: ("DF8E1D", "F9E2AF")),
        // Gruvbox: light / dark
        .gruvbox: ThemePalette(
            windowBackground: ("FBF1C7", "282828"), surface: ("F9F5D7", "3C3836"),
            surfaceSecondary: ("EBDBB2", "32302F"), surfaceTertiary: ("D5C4A1", "282828"),
            cardBorder: ("D5C4A1", "504945"),
            brand: ("B16286", "D3869B"), gold: ("D65D0E", "FE8019"),
            ink: ("3C3836", "EBDBB2"), onBrand: ("FBF1C7", "282828"),
            green: ("98971A", "B8BB26"), red: ("CC241D", "FB4934"), warn: ("D79921", "FABD2F")),
        // Nord: Snow Storm (light) / Polar Night (dark)
        .nord: ThemePalette(
            windowBackground: ("ECEFF4", "2E3440"), surface: ("FFFFFF", "3B4252"),
            surfaceSecondary: ("E5E9F0", "434C5E"), surfaceTertiary: ("D8DEE9", "2E3440"),
            cardBorder: ("D8DEE9", "4C566A"),
            brand: ("5E81AC", "81A1C1"), gold: ("D08770", "D08770"),
            ink: ("2E3440", "D8DEE9"), onBrand: ("ECEFF4", "2E3440"),
            green: ("A3BE8C", "A3BE8C"), red: ("BF616A", "BF616A"), warn: ("D08770", "D08770")),
        // Solarized: light / dark (same set of low-contrast accents)
        .solarized: ThemePalette(
            windowBackground: ("EEE8D5", "002B36"), surface: ("FDF6E3", "073642"),
            surfaceSecondary: ("E8E0C8", "073642"), surfaceTertiary: ("EEE8D5", "002B36"),
            cardBorder: ("DDD6C1", "586E75"),
            brand: ("268BD2", "268BD2"), gold: ("CB4B16", "CB4B16"),
            ink: ("657B83", "839496"), onBrand: ("FDF6E3", "002B36"),
            green: ("859900", "859900"), red: ("DC322F", "DC322F"), warn: ("B58900", "B58900")),
        // Rosé Pine: Dawn (light) / Main (dark)
        .rosepine: ThemePalette(
            windowBackground: ("FAF4ED", "191724"), surface: ("FFFAF3", "1F1D2E"),
            surfaceSecondary: ("F2E9E1", "26233A"), surfaceTertiary: ("F4EDE8", "191724"),
            cardBorder: ("DFDAD9", "26233A"),
            brand: ("907AA9", "C4A7E7"), gold: ("EA9D34", "F6C177"),
            ink: ("575279", "E0DEF4"), onBrand: ("FAF4ED", "191724"),
            green: ("286983", "31748F"), red: ("B4637A", "EB6F92"), warn: ("EA9D34", "F6C177")),
        // One Dark / One Light (Atom legacy)
        .onedark: ThemePalette(
            windowBackground: ("FAFAFA", "282C34"), surface: ("FFFFFF", "2C313A"),
            surfaceSecondary: ("F0F0F0", "21252B"), surfaceTertiary: ("EAEAEA", "282C34"),
            cardBorder: ("E0E0E0", "3B4048"),
            brand: ("4078F2", "61AFEF"), gold: ("C18401", "E5C07B"),
            ink: ("383A42", "ABB2BF"), onBrand: ("FAFAFA", "282C34"),
            green: ("50A14F", "98C379"), red: ("E45649", "E06C75"), warn: ("986801", "D19A66")),
        // Kanagawa: Lotus (light) / Wave (dark), ukiyo-e tones
        .kanagawa: ThemePalette(
            windowBackground: ("F2ECBC", "1F1F28"), surface: ("FAF3D2", "2A2A37"),
            surfaceSecondary: ("E5DDB0", "232329"), surfaceTertiary: ("DCD5A8", "16161D"),
            cardBorder: ("D5CEA3", "363646"),
            brand: ("4D699B", "7E9CD8"), gold: ("CC6D00", "FFA066"),
            ink: ("545464", "DCD7BA"), onBrand: ("F2ECBC", "1F1F28"),
            green: ("6F894E", "98BB6C"), red: ("C84053", "E46876"), warn: ("77713F", "FF9E3B")),
    ]

    // MARK: - Brand accent colors

    /// Primary accent: classic = indigo-purple (from the app icon, auto-brightened in dark mode);
    /// brutal = cyan; palette themes = each theme's brand
    static var brand: Color {
        switch ThemeStyle.current {
        case .classic: return classicBrand
        case .brutal: return Color(hex: "27CCF3")  // same value in light and dark; works on both cream and dark backgrounds
        default: return themedColor(\.brand)
        }
    }

    private static let classicBrand = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.55, green: 0.55, blue: 0.96, alpha: 1)
            : NSColor(srgbRed: 0.36, green: 0.36, blue: 0.89, alpha: 1)
    }))

    /// Secondary accent: classic = gold (from the app icon); brutal = pink; palette themes = each
    /// theme's gold
    static var gold: Color {
        switch ThemeStyle.current {
        case .classic: return classicGold
        case .brutal: return Color(hex: "FE7DA8")
        default: return themedColor(\.gold)
        }
    }

    private static let classicGold = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.89, green: 0.74, blue: 0.38, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.62, blue: 0.15, alpha: 1)
    }))

    /// Accent text tier: for thin text / icon foregrounds (color-block fills keep using brand /
    /// gold itself). brutal's neon cyan/pink is only 1.8–2.4:1 on cream, so as a foreground it must
    /// be darkened to ≥4.5:1; classic / palette themes use the same value as the base
    /// (pixel-identical); brutal's dark-mode base already passes and is reused.
    static var brandFg: Color {
        ThemeStyle.current == .brutal
            ? dynamic(light: hexRGB("0E7490"), dark: hexRGB("27CCF3"))
            : brand
    }

    static var goldFg: Color {
        ThemeStyle.current == .brutal
            ? dynamic(light: hexRGB("C2185B"), dark: hexRGB("FE7DA8"))
            : gold
    }

    /// Money blue: classic / palette themes always use system blue (existing convention); brutal
    /// uses a flat cobalt blue (light 6.7:1 / dark 5.8:1, keeping distance from the cyan brand
    /// color).
    static var cost: Color {
        ThemeStyle.current == .brutal
            ? dynamic(light: hexRGB("1D4ED8"), dark: hexRGB("6C9EF8"))
            : .blue
    }

    /// Ink: brutal's border / hard shadow / emphasis text color (light #141111, dark cream
    /// #FFFAEF). In palette themes ink = each theme's body foreground (used for selected strokes
    /// and the like).
    static var ink: Color {
        switch ThemeStyle.current {
        case .classic: return classicCardBorder
        case .brutal: return dynamic(light: hexRGB("141111"), dark: hexRGB("FFFAEF"))
        default: return themedColor(\.ink)
        }
    }

    /// Purple-gold gradient: color spines / badge fills all come from here (don't hand-write it in
    /// views). brutal doesn't use gradients: degrades to flat ink; palette themes keep a brand→gold
    /// gradient (in their own colors).
    static var purpleGoldGradient: LinearGradient {
        switch ThemeStyle.current {
        case .brutal:
            return LinearGradient(colors: [ink, ink], startPoint: .top, endPoint: .bottom)
        default:
            return LinearGradient(colors: [brand, gold], startPoint: .top, endPoint: .bottom)
        }
    }

    /// Brand small-tile gradient (Indigo Light → brand → Indigo Deep, top-left → bottom-right). For
    /// ~24pt tiles: a vertical purple-gold gradient muddies into olive at this size, so small tiles
    /// stay purple-only and gold is left to the stroke ring. Non-classic styles degrade to the flat
    /// brand color.
    static var brandTileGradient: LinearGradient {
        switch ThemeStyle.current {
        case .classic:
            return LinearGradient(
                colors: [Color(hex: "8C8CF5"), brand, Color(hex: "4A45C9")],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return LinearGradient(
                colors: [brand, brand],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    /// Chart bar gradient (#8C8CF5 → #5C5CE3, top to bottom; for the last-30-days call bar chart).
    /// Non-classic styles degrade to the flat brand color.
    static var chartBarGradient: LinearGradient {
        switch ThemeStyle.current {
        case .classic:
            return LinearGradient(
                colors: [
                    Color(.sRGB, red: 0.55, green: 0.55, blue: 0.96, opacity: 1),
                    Color(.sRGB, red: 0.36, green: 0.36, blue: 0.89, opacity: 1),
                ],
                startPoint: .top, endPoint: .bottom)
        default:
            return LinearGradient(
                colors: [brand, brand],
                startPoint: .top, endPoint: .bottom)
        }
    }

    // MARK: - Semantic status colors (consolidating switches duplicated across the repo)

    /// Enabled green
    static var enabledGreen: Color {
        switch ThemeStyle.current {
        case .classic:
            return Color(.sRGB, red: 0.20, green: 0.78, blue: 0.35, opacity: 1)
        case .brutal:  // brutal green (darkened to 5.0:1 in light mode so small text stays readable, brightened in dark)
            return dynamic(light: hexRGB("3F7A25"), dark: hexRGB("A9D877"))
        default: return themedColor(\.green)
        }
    }
    /// Disabled grey: classic / palette themes = cool grey; brutal = warm grey at the same
    /// lightness (cool grey looks dirty on warm cream)
    static var disabledGray: Color {
        ThemeStyle.current.isHardEdged
            ? Color(hex: "DBD5C6")
            : Color(.sRGB, red: 0.86, green: 0.86, blue: 0.88, opacity: 1)
    }
    /// Failure red
    static var failureRed: Color {
        switch ThemeStyle.current {
        case .classic:
            return Color(.sRGB, red: 0.82, green: 0.27, blue: 0.23, opacity: 1)
        case .brutal:  // light #F97264 is only 2.8:1, so it's darkened; dark keeps the original coral red
            return dynamic(light: hexRGB("C92A2A"), dark: hexRGB("F97264"))
        default: return themedColor(\.red)
        }
    }
    /// Auto-clean grey: classic / palette themes = cool grey; brutal = warm grey at the same
    /// lightness
    static var autoCleanGray: Color {
        ThemeStyle.current.isHardEdged
            ? Color(hex: "A49E90")
            : Color(.sRGB, red: 0.64, green: 0.64, blue: 0.66, opacity: 1)
    }
    /// Draft grey (plan status): classic / palette themes = cool grey #CFCFD6; brutal = warm grey
    /// at the same lightness
    static var draftGray: Color {
        ThemeStyle.current.isHardEdged ? Color(hex: "CFC8B8") : Color(hex: "CFCFD6")
    }

    /// Warning orange
    private static var warnColor: Color {
        switch ThemeStyle.current {
        case .classic: return .orange
        case .brutal:  // light darkened to 4.8:1 (#D96F32 is only 3.2:1), dark #F8A16F
            return dynamic(light: hexRGB("B45309"), dark: hexRGB("F8A16F"))
        default: return themedColor(\.warn)
        }
    }

    /// Task outcome: success green / error red / interrupted grey
    static func outcomeColor(_ outcome: TaskOutcome) -> Color {
        if ThemeStyle.current.isThemed {
            switch outcome {
            case .success: return enabledGreen
            case .error: return failureRed
            case .interrupted: return autoCleanGray
            }
        }
        switch outcome {
        case .success: return .green
        case .error: return .red
        case .interrupted: return .gray
        }
    }

    /// Risk level colors. `.red`/`.orange` used to be hardcoded in three places in AuditView,
    /// inconsistently.
    static func riskColor(_ level: RiskLevel) -> Color {
        switch level {
        case .high: return failureRed
        case .notice: return goldFg  // thin badge text, so use the text tier
        }
    }

    /// Usage ratio thresholds: <60 green / <85 orange / otherwise red (shared by rate limits and
    /// ctx%)
    static func percentColor(_ percent: Double) -> Color {
        if ThemeStyle.current.isThemed {
            switch percent {
            case ..<60: return enabledGreen
            case ..<85: return warnColor
            default: return failureRed
            }
        }
        switch percent {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    /// Integration install status
    static func installColor(_ status: InstallStatus) -> Color {
        if ThemeStyle.current.isThemed {
            switch status {
            case .installed: return enabledGreen
            case .partial, .foreign: return warnColor
            case .none: return autoCleanGray
            }
        }
        switch status {
        case .installed: return .green
        case .partial, .foreign: return .orange
        case .none: return .gray
        }
    }

    /// Data source health status
    static func healthColor(_ status: HealthRegistry.Entry.Status) -> Color {
        if ThemeStyle.current.isThemed {
            switch status {
            case .ok: return enabledGreen
            case .degraded: return warnColor
            case .stalled: return failureRed
            case .idle: return autoCleanGray
            }
        }
        switch status {
        case .ok: return .green
        case .degraded: return .orange
        case .stalled: return .red
        case .idle: return .gray
        }
    }

    // MARK: - Neutral backgrounds

    /// Card background: classic = system controlBackground; brutal = white card (dark #28241F warm
    /// grey)
    static var surface: Color {
        switch ThemeStyle.current {
        case .classic: return Color(nsColor: .controlBackgroundColor)
        case .brutal: return dynamic(light: hexRGB("FFFFFF"), dark: hexRGB("28241F"))
        default: return themedColor(\.surface)
        }
    }

    /// Group header / toolbar / hover background
    static var surfaceSecondary: Color {
        switch ThemeStyle.current {
        case .classic: return Color.primary.opacity(0.05)
        case .brutal: return dynamic(light: hexRGB("F5EEDD"), dark: hexRGB("241F1A"))
        default: return themedColor(\.surfaceSecondary)
        }
    }

    /// Lighter container background (tables, log areas)
    static var surfaceTertiary: Color {
        switch ThemeStyle.current {
        case .classic: return Color.primary.opacity(0.03)
        case .brutal: return dynamic(light: hexRGB("EFE7D2"), dark: hexRGB("201C17"))
        default: return themedColor(\.surfaceTertiary)
        }
    }

    /// Divider / thin stroke
    static var hairline: Color {
        switch ThemeStyle.current {
        case .classic: return Color.primary.opacity(0.08)
        case .brutal:
            return dynamicAlpha(light: hexRGBA("141111", 0.3), dark: hexRGBA("FFFAEF", 0.3))
        default:
            // Palette themes: each theme's body color at 12% (same idea as classic's primary at 8%,
            // only the color source changes)
            return ink.opacity(0.12)
        }
    }

    /// Card / tile stroke: classic = light grey border (the reference mockup's minimal style);
    /// brutal = ink (dark = cream)
    static var cardBorder: Color {
        switch ThemeStyle.current {
        case .classic: return classicCardBorder
        case .brutal: return ink
        default: return themedColor(\.cardBorder)
        }
    }

    private static let classicCardBorder = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.14)
            : NSColor(srgbRed: 0.89, green: 0.89, blue: 0.91, alpha: 1)  // #E2E2E8
    }))

    /// Light brand-tinted fill (selected state / badges / highlighted rows)
    static func brandFill(_ opacity: Double = 0.10) -> Color {
        brand.opacity(opacity)
    }

    // MARK: - Theme-varying tokens (classic and palette themes keep the original behavior, brutal takes structural values)

    /// Card stroke width: classic / palette themes 0.5 thin border; brutal 2px ink border
    static var cardBorderWidth: CGFloat {
        ThemeStyle.current.isHardEdged ? 2 : 0.5
    }

    /// Card-level shadow (brutal = zero-blur 4/4 ink shadow; others = nil, handled by the
    /// components' classic soft shadow). SwiftUI `.shadow(radius: 0)` is a zero-blur hard shadow.
    static var cardShadow: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat)? {
        ThemeStyle.current.isHardEdged ? (ink, 0, 4, 4) : nil
    }

    /// Small-control shadow (capsule / button level; brutal = 2/2)
    static var controlShadow: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat)? {
        ThemeStyle.current.isHardEdged ? (ink, 0, 2, 2) : nil
    }

    /// Control outline (selected capsule / logo tile / mini switch outline): brutal only = ink 2;
    /// others = nil (each component falls back to its original logic)
    static var controlOutline: (color: Color, width: CGFloat)? {
        ThemeStyle.current.isHardEdged ? (ink, 2) : nil
    }

    /// Mini switch knob color: classic / palette themes = white; brutal = cream
    static var controlKnob: Color {
        ThemeStyle.current.isHardEdged ? Color(hex: "FFFAEF") : .white
    }

    /// Text / icon color on a selected brand fill: classic = white; brutal = ink (on cyan)
    static var onBrand: Color {
        switch ThemeStyle.current {
        case .classic: return .white
        case .brutal: return ink
        default: return themedColor(\.onBrand)
        }
    }

    /// Main window background: classic = clear (keeps the system window background); brutal = cream
    /// (dark = warm black)
    static var windowBackground: Color {
        switch ThemeStyle.current {
        case .classic: return .clear
        case .brutal: return dynamic(light: hexRGB("FFFAEF"), dark: hexRGB("171410"))
        default: return themedColor(\.windowBackground)
        }
    }

    // MARK: - Context usage category colors (session detail's "context usage" card: shared by stacked bar segments + legend dots)

    /// Five category colors: classic / palette themes = the reference image's
    /// teal/yellow/purple/light blue/blue-violet (one set each for light and dark); brutal = flat
    /// neon cyan/yellow/purple/blue/green (same in light and dark, flat without gradients).
    static func contextCategoryColor(_ category: ContextBreakdown.Category) -> Color {
        if ThemeStyle.current.isHardEdged {
            switch category {
            case .systemPrompt: return Color(hex: "27CCF3")  // cyan
            case .tools: return Color(hex: "F5C518")         // yellow
            case .messages: return Color(hex: "B98CFF")      // purple
            case .mcp: return Color(hex: "6C9EF8")           // blue
            case .skills: return Color(hex: "A9D877")        // green
            }
        }
        switch category {
        case .systemPrompt: return dynamic(light: hexRGB("2FA98C"), dark: hexRGB("5CCBAD"))
        case .tools: return dynamic(light: hexRGB("D9A62E"), dark: hexRGB("E8C25C"))
        case .messages: return dynamic(light: hexRGB("7C5CFC"), dark: hexRGB("9D8AFA"))
        case .mcp: return dynamic(light: hexRGB("5BA8D9"), dark: hexRGB("7FC2E8"))
        case .skills: return dynamic(light: hexRGB("6B6BD6"), dark: hexRGB("8F8FE8"))
        }
    }

    // MARK: - Role / plan status semantic colors (purple-gold mockup)

    /// Subagent role colors (the palette's "Roles · Agents"; implementer = brand purple, others
    /// take fixed palette values)
    static func roleColor(_ role: AgentRole) -> Color {
        switch role {
        case .general: return Color(hex: "8A8A90")
        case .explore: return Color(hex: "2A8FD4")
        case .implement: return brand
        case .review: return Color(hex: "B08A1E")
        case .plan: return Color(hex: "7A5CF0")
        case .model: return Color(hex: "C2762A")
        case .doc: return Color(hex: "2CA24A")
        }
    }

    /// Plan status colors: done green / in-progress purple / draft grey / document gold (thin badge
    /// text, so accents use the text tier)
    static func planStatusColor(_ status: PlanMaterializer.PlanStatus) -> Color {
        switch status {
        case .complete: return enabledGreen
        case .inProgress: return brandFg
        case .draft: return draftGray
        case .document: return goldFg
        }
    }

    // MARK: - Spacing (Codex-style generous whitespace: large gaps between modules, comfortable card padding; same across styles)

    enum spacing {
        /// Gap between modules (cards/groups)
        static let module: CGFloat = 22
        /// Page content margin
        static let page: CGFloat = 16
        /// Card padding
        static let card: CGFloat = 16
        /// List row vertical padding
        static let row: CGFloat = 9
        /// Gap between inline elements
        static let item: CGFloat = 6
    }

    // MARK: - Corner radii (classic minimal ladder 14/10/8/8; brutal small and hard 7/5/3/7; palette themes follow classic)

    enum radius {
        /// Cards / large containers
        static var card: CGFloat { ThemeStyle.current.isHardEdged ? 7 : 14 }
        /// Small containers (stat tiles, embedded panels)
        static var container: CGFloat { ThemeStyle.current.isHardEdged ? 5 : 10 }
        /// Small tiles (logo tiles / icon tiles) and sidebar nav items
        static var tile: CGFloat { ThemeStyle.current.isHardEdged ? 3 : 8 }
        /// Sidebar nav items
        static var sidebar: CGFloat { ThemeStyle.current.isHardEdged ? 7 : 8 }
    }

    // MARK: - Font sizes (classic / palette themes = SF system font; brutal = Space Grotesk / Space Mono, same sizes)

    enum font {
        /// Page title 14/700
        static var pageTitle: Font { themed(14, .bold) }
        /// Card title 13.5/650 (monospaced skill names use monoSkillName)
        static var cardTitle: Font { themed(13.5, .semibold) }
        /// Monospaced skill name (classic / palette themes = SF Mono; brutal = Space Mono)
        static func monoSkillName(_ size: CGFloat = 13.5, weight: Font.Weight = .semibold) -> Font {
            ThemeStyle.current.isHardEdged
                ? ThemeFonts.mono(size, weight: weight)
                : .system(size: size, weight: weight, design: .monospaced)
        }
        /// Body 12.5
        static var body: Font { themed(12.5) }
        /// Secondary 11
        static var secondary: Font { themed(11) }
        /// Caption 9.5–10
        static var caption: Font { themed(9.5) }
        /// Big number 18–23/700 with monospaced digits
        static func statNumber(_ size: CGFloat = 18) -> Font {
            ThemeStyle.current.isHardEdged
                ? ThemeFonts.mono(size, weight: .bold)
                : .system(size: size, weight: .bold).monospacedDigit()
        }

        /// Themed replacement for inline `.font(.system(size:weight:))` in views: classic / palette
        /// themes return the system font unchanged (pixel-identical); brutal maps to Space Grotesk.
        static func themed(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            ThemeStyle.current.isHardEdged
                ? ThemeFonts.grotesk(size, weight: weight)
                : .system(size: size, weight: weight)
        }

        /// Themed replacement for inline monospaced-digit fonts: classic / palette themes = system
        /// + monospacedDigit; brutal = Space Mono.
        static func themedMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            ThemeStyle.current.isHardEdged
                ? ThemeFonts.mono(size, weight: weight)
                : .system(size: size, weight: weight).monospacedDigit()
        }
    }

    // MARK: - Private helpers

    /// Palette theme color lookup: reads the palette table and builds a dark/light pair
    private static func themedColor(_ key: KeyPath<ThemePalette, (String, String)>) -> Color {
        guard let pair = palettes[ThemeStyle.current]?[keyPath: key] else { return .primary }
        return dynamic(light: hexRGB(pair.0), dark: hexRGB(pair.1))
    }

    /// hex → sRGB components
    private static func hexRGB(_ hex: String) -> (r: Double, g: Double, b: Double) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        return (Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255)
    }

    private static func hexRGBA(_ hex: String, _ alpha: Double) -> (r: Double, g: Double, b: Double, a: Double) {
        let rgb = hexRGB(hex)
        return (rgb.r, rgb.g, rgb.b, alpha)
    }

    /// Dark/light color pair
    private static func dynamic(
        light: (r: Double, g: Double, b: Double), dark: (r: Double, g: Double, b: Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: dark.r, green: dark.g, blue: dark.b, alpha: 1)
                : NSColor(srgbRed: light.r, green: light.g, blue: light.b, alpha: 1)
        }))
    }

    /// Dark/light color pair with alpha
    private static func dynamicAlpha(
        light: (r: Double, g: Double, b: Double, a: Double),
        dark: (r: Double, g: Double, b: Double, a: Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: dark.r, green: dark.g, blue: dark.b, alpha: dark.a)
                : NSColor(srgbRed: light.r, green: light.g, blue: light.b, alpha: light.a)
        }))
    }
}

extension Color {
    /// Creates a color from `#RRGGBB` / `RRGGBB` / `#RRGGBBAA` hex (makes it easy to hit exact
    /// palette values).
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b, a: Double
        if cleaned.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
