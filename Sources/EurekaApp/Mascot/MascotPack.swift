import AppKit
import EurekaIngest
import EurekaKit
import Foundation

/// Animation asset for one state: a looping PNG frame sequence or a self-playing GIF/APNG
enum MascotAnimation: Equatable {
    case frames([URL], fps: Double)
    case animatedImage(URL)
    /// Arbitrary frame sequence within a sprite sheet. Grid size travels with the atlas, compatible
    /// with v2 and later extensions.
    case spriteSequence(MascotSpriteSheet, cells: [MascotSpriteCell], fps: Double)
}

struct MascotSpriteSheet: Equatable {
    var url: URL
    var grid: MascotSpriteGrid
}

struct MascotSpriteCell: Equatable {
    var row: Int
    var column: Int
}

/// Behavior variant within one state. Animation, caption and subtle body language can be combined
/// independently.
struct MascotVariant: Equatable {
    var id: String
    var animation: MascotAnimation
    var caption: String?
    var motion: MascotMotionProfile = .stateDefault
    var weight: Int = 1
    var playback: MascotPlaybackMode = .loop
}

/// Per-variant body language. Better than hardcoding per state for micro-behaviors like blinking,
/// watching and nudging.
enum MascotMotionProfile: String, Equatable {
    case stateDefault
    case gentle
    case focus
    case curious
    case nudge
    case celebrate
    case droop
    case sleep
    case sway
    case still
}

/// A mascot animation pack (built-in or user-imported)
struct MascotPack {
    var id: String
    var name: String
    var states: [MascotState: MascotAnimation]
    /// English word-art captions on the sticker (per state)
    var captions: [MascotState: String] = [:]
    /// High-frequency states may have several behavior variants; older packs without them are
    /// wrapped into one default variant.
    var variants: [MascotState: [MascotVariant]] = [:]
    /// 16-direction gaze provided by v2 assets, clockwise starting at 000° (up).
    var lookDirections: [MascotAnimation] = []

    /// Built-in default English captions (a pack can override them via the manifest's "captions")
    static var defaultCaptions: [MascotState: String] { [
        .idle: L10n.text("HELLO", zhHans: "你好"), .working: L10n.text("FOCUS", zhHans: "专注"), .waiting: L10n.text("HEY!", zhHans: "嘿！"), .success: L10n.text("DONE!", zhHans: "完成！"),
        .error: L10n.text("OOPS", zhHans: "哎呀"), .sleeping: L10n.text("ZZZ", zhHans: "呼呼"), .relax: L10n.text("RELAX", zhHans: "放松"), .night: L10n.text("SLEEPY", zhHans: "困了"),
        .poke: L10n.text("HEHE~", zhHans: "嘿嘿～"), .wake: L10n.text("MORNING!", zhHans: "早上好！"),
    ] }

    /// Pose set rotated while idle. Kept for older callers; new logic uses variants(for:).
    var idlePoses: [MascotAnimation] {
        var result: [MascotAnimation] = []
        for variant in variants(for: .idle) where !result.contains(variant.animation) {
            result.append(variant.animation)
        }
        return result
    }

    /// Returns all variants for a state. If missing, follows the usual fallback chain and finally
    /// wraps one default variant.
    func variants(for state: MascotState) -> [MascotVariant] {
        var current = state
        for _ in 0..<MascotState.allCases.count {
            if let direct = variants[current], !direct.isEmpty { return direct }
            if let animation = states[current] {
                return [MascotVariant(
                    id: "\(current.rawValue)-default",
                    animation: animation,
                    caption: captions[current],
                    motion: .stateDefault)]
            }
            let next = current.fallback
            if next == current { break }
            current = next
        }
        return []
    }

    func lookAnimation(direction: Int) -> MascotAnimation? {
        guard lookDirections.indices.contains(direction) else { return nil }
        return lookDirections[direction]
    }

    /// Animation for a state; if missing, follow the fallback chain, ending at idle
    func animation(for state: MascotState) -> MascotAnimation? {
        if let direct = states[state] { return direct }
        var current = state
        for _ in 0..<MascotState.allCases.count {
            let next = current.fallback
            if let found = states[next] { return found }
            if next == current { break }  // idle.fallback == idle, end of chain
            current = next
        }
        return states[.idle]
    }
}

enum MascotPackLoader {
    static let builtInID = "built-in"
    static var builtInName: String { L10n.text("Lulu & Lumei (Built-in)", zhHans: "噜噜 & 噜妹（内置）") }

    /// Root directory for user custom packs: ~/Library/Application Support/Eureka/mascots
    static func customRoot() -> URL {
        SpoolPaths.root().appendingPathComponent("mascots", isDirectory: true)
    }

    /// Ensure mascots/ exists and drop a readme + sample manifest (first time), then open it in
    /// Finder
    static func revealCustomFolder() {
        let root = customRoot()
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        // The file name follows the current language. An existing readme in the other language
        // stays put; user-edited files are never overwritten.
        let readme = root.appendingPathComponent(L10n.text(
            "how-to-make-an-animation-pack.txt",
            zhHans: "如何制作动画包.txt"))
        if !fm.fileExists(atPath: readme.path) {
            try? sampleReadme.write(to: readme, atomically: true, encoding: .utf8)
        }
        let example = root.appendingPathComponent("manifest.example.json")
        if !fm.fileExists(atPath: example.path) {
            try? sampleManifest.write(to: example, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(root)
    }

    private static var sampleReadme: String {
        L10n.text(
            """
            Eureka desktop companion · custom animation pack
            ================================================

            1. Inside this folder (mascots/), create a subfolder. Its name is the pack name, for example my-lulu/.
            2. Put the images in that subfolder, plus a manifest.json (copy manifest.example.json from this folder and edit it).
            3. Each state can be:
               - one gif/apng filename (plays automatically), e.g. "waiting": "wait.gif"
               - an array of png/jpg frame filenames (loops at fps), e.g. "working": ["w1.png","w2.png"]
            4. States: idle / working / waiting / success / error / sleeping / relax / night / poke / wake
               - provide idle art or idle variants; anything missing falls back along the state chain.
            5. Optional variants: several behaviors for one state. Each item may set id / frames or file / fps /
               caption / motion / weight. motion is one of gentle/focus/curious/nudge/celebrate/
               droop/sleep/sway/still.
            6. Back in Eureka: Settings → Desktop companion → Animation pack, then pick your pack (a new pack may need the settings panel reopened to refresh the list).

            Suggested size: square, long edge ≤ 512px. A transparent or solid background is fine (it sits in a rounded card).
            """,
            zhHans: """
            Eureka 桌面吉祥物 · 自定义动画包
            ================================

            1. 在本文件夹(mascots/)下新建一个子文件夹,名字即包名,例如:my-lulu/
            2. 把图片放进去,并在该子文件夹里放一个 manifest.json(可复制同级的 manifest.example.json 改)。
            3. 每个状态(state)可以是:
               - 一个 gif/apng 文件名(自动播放),如 "waiting": "wait.gif"
               - 一组 png/jpg 帧文件名数组(按 fps 循环),如 "working": ["w1.png","w2.png"]
            4. 状态全集:idle / working / waiting / success / error / sleeping / relax / night / poke / wake
               - idle 素材或 idle variants 至少提供一种;其余缺失会自动沿状态链回退。
            5. 可选 variants:给同一个状态配置多个行为,每项支持 id / frames 或 file / fps /
               caption / motion / weight。motion 可选 gentle/focus/curious/nudge/celebrate/
               droop/sleep/sway/still。
            6. 回 Eureka 设置 → 桌面伙伴 → 动画包,选你的包即可(新建后可能需重开设置面板刷新列表)。

            建议尺寸:正方形,长边 ≤ 512px;透明或纯色背景都行(会放进圆角卡片里)。
            """)
    }

    private static var sampleManifest: String {
        let name = L10n.text("My mascot pack", zhHans: "我的表情包")
        return """
    {
      "name": "\(name)",
      "fps": 2,
      "states": {
        "idle": ["idle-1.png", "idle-2.png"],
        "working": ["working-1.png", "working-2.png"],
        "waiting": "waiting.gif",
        "success": ["success-1.png", "success-2.png"],
        "error": "error.png",
        "sleeping": ["sleeping-1.png", "sleeping-2.png"],
        "relax": ["relax-1.png", "relax-2.png"],
        "night": ["night-1.png", "night-2.png"],
        "poke": ["poke-1.png", "poke-2.png"],
        "wake": "wake.png"
      },
      "variants": {
        "idle": [
          {
            "id": "blink",
            "frames": ["idle-1.png", "idle-2.png"],
            "fps": 3,
            "caption": "HI~",
            "motion": "gentle",
            "weight": 3
          }
        ]
      }
    }
    """
    }

    /// Built-in pack: scene stickers and the v2 two-character sprite sheet together provide state
    /// variants.
    static func builtIn() -> MascotPack {
        func frames(_ names: [String]) -> MascotAnimation {
            let urls = names.compactMap {
                AppResources.bundle.url(
                    forResource: $0, withExtension: "png", subdirectory: "mascots/lulu")
            }
            return .frames(urls, fps: 2)
        }
        let legacyStates: [MascotState: MascotAnimation] = [
            .idle: frames(["idle-1"]),            // Lulu pondering, chin in hand
            .working: frames(["working-1", "working-2"]),
            .waiting: frames(["waiting-1"]),      // Lulu raising a finger to call out
            .success: frames(["success-1", "success-2"]),
            .error: frames(["error-1"]),          // Lumei sweating, dejected
            .sleeping: frames(["sleeping-1", "sleeping-2", "sleeping-3"]),
            .relax: frames(["relax-1", "relax-2", "relax-3"]),
            .night: frames(["night-1", "night-2"]),
            .poke: frames(["poke-1", "poke-2"]),
            .wake: frames(["wake-1"]),
        ]
        var pack = MascotPack(
            id: builtInID, name: builtInName,
            states: legacyStates, captions: MascotPack.defaultCaptions)

        // Even if the extended sprite sheet is missing, the old scenes provide 12 high-frequency
        // variants instead of falling back to a single sticker loop.
        pack.variants = [
            .idle: [
                MascotVariant(id: "lulu-thinking", animation: legacyStates[.idle]!,
                              caption: L10n.text("THINK", zhHans: "思考"), motion: .curious, weight: 3),
                MascotVariant(id: "lumei-lounging", animation: legacyStates[.relax]!,
                              caption: L10n.text("CHILL", zhHans: "放松一下"), motion: .sway, weight: 2),
                MascotVariant(id: "lumei-soft-nap", animation: legacyStates[.sleeping]!,
                              caption: L10n.text("NAP", zhHans: "小憩"), motion: .sleep, weight: 1),
                MascotVariant(id: "lulu-bright-idea", animation: legacyStates[.waiting]!,
                              caption: L10n.text("IDEA!", zhHans: "有主意！"), motion: .gentle, weight: 2),
            ],
            .working: [
                MascotVariant(id: "lulu-coding", animation: legacyStates[.working]!,
                              caption: L10n.text("FOCUS", zhHans: "专注"), motion: .focus, weight: 4),
                MascotVariant(id: "lulu-deep-focus", animation: legacyStates[.working]!,
                              caption: L10n.text("FLOW", zhHans: "心流"), motion: .still, weight: 3),
                MascotVariant(id: "lulu-reviewing", animation: legacyStates[.success]!,
                              caption: L10n.text("CHECK", zhHans: "检查"), motion: .gentle, weight: 2),
                MascotVariant(id: "lulu-late-shift", animation: legacyStates[.night]!,
                              caption: L10n.text("STILL ON", zhHans: "还在忙"), motion: .sleep, weight: 1),
            ],
            .waiting: [
                MascotVariant(id: "lulu-calling", animation: legacyStates[.waiting]!,
                              caption: L10n.text("HEY!", zhHans: "嘿！"), motion: .nudge, weight: 4),
                MascotVariant(id: "lulu-gentle-reminder", animation: legacyStates[.waiting]!,
                              caption: L10n.text("AHEM", zhHans: "咳咳"), motion: .gentle, weight: 3),
                MascotVariant(id: "lulu-thinking-wait", animation: legacyStates[.idle]!,
                              caption: L10n.text("HMM?", zhHans: "嗯？"), motion: .curious, weight: 2),
                MascotVariant(id: "lumei-waiting", animation: legacyStates[.relax]!,
                              caption: L10n.text("YOUR TURN", zhHans: "到你啦"), motion: .nudge, weight: 1),
            ],
        ]

        if let atlas = AppResources.bundle.url(
            forResource: "lulu-lumei-duo-v2", withExtension: "png",
            subdirectory: "mascots/lulu") {
            let v2Sheet = MascotSpriteSheet(
                url: atlas, grid: MascotSpriteGrid(columns: 8, rows: 11))
            func sprite(row: Int, columns: [Int], fps: Double) -> MascotAnimation {
                .spriteSequence(
                    v2Sheet,
                    cells: columns.map { MascotSpriteCell(row: row, column: $0) },
                    fps: fps)
            }

            // v2 rows provide the real two-character animation; the old 3D scenes stay as
            // alternating single-character variants.
            pack.variants[.idle]?.insert(contentsOf: [
                MascotVariant(id: "duo-breathing", animation: sprite(
                    row: 0, columns: [0, 1, 2, 3, 4, 5], fps: 3),
                    caption: nil, motion: .gentle, weight: 5),
                MascotVariant(id: "duo-blink", animation: sprite(
                    row: 0, columns: [0, 1, 0, 2, 0, 1], fps: 2.5),
                    caption: L10n.text("HI~", zhHans: "嗨～"), motion: .still, weight: 4),
            ], at: 0)
            pack.variants[.working]?.insert(contentsOf: [
                MascotVariant(id: "duo-focus", animation: sprite(
                    row: 7, columns: [0, 1, 2, 3, 4, 5], fps: 4),
                    caption: L10n.text("TOGETHER", zhHans: "一起努力"), motion: .focus, weight: 5),
                MascotVariant(id: "duo-review", animation: sprite(
                    row: 8, columns: [0, 1, 2, 3, 4, 5], fps: 3),
                    caption: L10n.text("CHECK", zhHans: "检查"), motion: .curious, weight: 4),
            ], at: 0)
            pack.variants[.waiting]?.insert(contentsOf: [
                MascotVariant(id: "duo-awaiting", animation: sprite(
                    row: 6, columns: [0, 1, 2, 3, 4, 5], fps: 3),
                    caption: L10n.text("NEED YOU", zhHans: "需要你"), motion: .nudge, weight: 5),
                MascotVariant(id: "duo-wave", animation: sprite(
                    row: 3, columns: [0, 1, 2, 3], fps: 4),
                    caption: L10n.text("OVER HERE!", zhHans: "看这里！"), motion: .gentle, weight: 4),
            ], at: 0)
            pack.variants[.success] = [
                MascotVariant(id: "duo-jump", animation: sprite(
                    row: 4, columns: [0, 1, 2, 3, 4], fps: 5),
                    caption: L10n.text("WE DID IT!", zhHans: "我们做到了！"), motion: .celebrate, weight: 5,
                    playback: .onceHoldLast),
                MascotVariant(id: "duo-happy-wave", animation: sprite(
                    row: 3, columns: [0, 1, 2, 3], fps: 4),
                    caption: L10n.text("YAY!", zhHans: "耶！"), motion: .celebrate, weight: 3,
                    playback: .onceHoldLast),
                MascotVariant(id: "lulu-finished", animation: legacyStates[.success]!,
                              caption: L10n.text("DONE!", zhHans: "完成！"), motion: .celebrate, weight: 2,
                              playback: .onceHoldLast),
            ]
            pack.variants[.error] = [
                MascotVariant(id: "duo-soft-fail", animation: sprite(
                    row: 5, columns: Array(0..<8), fps: 4),
                    caption: L10n.text("TRY AGAIN", zhHans: "再试一次"), motion: .droop, weight: 5,
                    playback: .onceHoldLast),
                MascotVariant(id: "lumei-oops", animation: legacyStates[.error]!,
                              caption: L10n.text("OOPS", zhHans: "哎呀"), motion: .droop, weight: 2,
                              playback: .onceHoldLast),
            ]
            pack.variants[.poke] = [
                MascotVariant(id: "duo-startled", animation: sprite(
                    row: 4, columns: [0, 1, 2, 3, 4], fps: 7),
                    caption: L10n.text("BOOP!", zhHans: "戳一戳！"), motion: .celebrate, weight: 3,
                    playback: .onceHoldLast),
                MascotVariant(id: "duo-wave-back", animation: sprite(
                    row: 3, columns: [0, 1, 2, 3], fps: 6),
                    caption: L10n.text("HEHE~", zhHans: "嘿嘿～"), motion: .gentle, weight: 2,
                    playback: .onceHoldLast),
            ]
            pack.variants[.wake] = [
                MascotVariant(id: "duo-wake-up", animation: sprite(
                    row: 4, columns: [0, 1, 2, 3, 4], fps: 5),
                    caption: L10n.text("AWAKE!", zhHans: "醒啦！"), motion: .gentle, weight: 1,
                    playback: .onceHoldLast),
            ]
            pack.lookDirections = (0..<16).map { direction in
                sprite(row: 9 + direction / 8, columns: [direction % 8], fps: 1)
            }
        }

        if let atlas = AppResources.bundle.url(
            forResource: "lulu-lumei-duo-v3", withExtension: "png",
            subdirectory: "mascots/lulu") {
            let v3Sheet = MascotSpriteSheet(
                url: atlas, grid: MascotSpriteGrid(columns: 4, rows: 12))
            func v3(row: Int, fps: Double) -> MascotAnimation {
                .spriteSequence(
                    v3Sheet,
                    cells: (0..<4).map { MascotSpriteCell(row: row, column: $0) },
                    fps: fps)
            }

            pack.variants[.idle, default: []].insert(MascotVariant(
                id: "duo-snack-share",
                animation: v3(row: 0, fps: 2),
                caption: L10n.text("SNACK?", zhHans: "吃点零食？"),
                motion: .gentle,
                weight: 4), at: 0)
            pack.variants[.working, default: []].insert(contentsOf: [
                MascotVariant(
                    id: "duo-pair-programming",
                    animation: v3(row: 1, fps: 4),
                    caption: L10n.text("PAIRING", zhHans: "结对编程"),
                    motion: .focus,
                    weight: 4),
                MascotVariant(
                    id: "lumei-bright-idea",
                    animation: v3(row: 2, fps: 3),
                    caption: L10n.text("GOT IT!", zhHans: "明白了！"),
                    motion: .curious,
                    weight: 3),
            ], at: 0)
            pack.variants[.waiting, default: []].insert(MascotVariant(
                id: "lulu-checklist-reminder",
                animation: v3(row: 3, fps: 3),
                caption: L10n.text("YOUR TURN", zhHans: "到你啦"),
                motion: .nudge,
                weight: 4), at: 0)
            pack.variants[.success, default: []].insert(MascotVariant(
                id: "duo-high-five",
                animation: v3(row: 4, fps: 5),
                caption: L10n.text("HIGH FIVE!", zhHans: "击个掌！"),
                motion: .celebrate,
                weight: 5,
                playback: .onceHoldLast), at: 0)
            pack.variants[.error, default: []].insert(contentsOf: [
                MascotVariant(
                    id: "lumei-comforts-lulu",
                    animation: v3(row: 5, fps: 2.5),
                    caption: L10n.text("I'M HERE", zhHans: "我在呢"),
                    motion: .gentle,
                    weight: 4,
                    playback: .onceHoldLast),
                MascotVariant(
                    id: "lulu-encourages-lumei",
                    animation: v3(row: 6, fps: 3),
                    caption: L10n.text("ONE MORE", zhHans: "再来一次"),
                    motion: .gentle,
                    weight: 4,
                    playback: .onceHoldLast),
            ], at: 0)
            pack.variants[.relax] = [
                MascotVariant(
                    id: "duo-tea-break",
                    animation: v3(row: 7, fps: 2),
                    caption: L10n.text("TEA BREAK", zhHans: "喝茶休息"),
                    motion: .sway,
                    weight: 4),
                MascotVariant(
                    id: "lumei-relaxing",
                    animation: legacyStates[.relax]!,
                    caption: L10n.text("RELAX", zhHans: "放松"),
                    motion: .sway,
                    weight: 2),
            ]
            pack.variants[.sleeping] = [
                MascotVariant(
                    id: "duo-cozy-sleep",
                    animation: v3(row: 8, fps: 1.5),
                    caption: L10n.text("COZY", zhHans: "暖暖的"),
                    motion: .sleep,
                    weight: 5),
                MascotVariant(
                    id: "lumei-sleeping",
                    animation: legacyStates[.sleeping]!,
                    caption: L10n.text("ZZZ", zhHans: "呼呼"),
                    motion: .sleep,
                    weight: 2),
            ]
            pack.variants[.night] = [
                MascotVariant(
                    id: "duo-bedtime",
                    animation: v3(row: 9, fps: 2),
                    caption: L10n.text("BEDTIME", zhHans: "该睡啦"),
                    motion: .sleep,
                    weight: 5),
                MascotVariant(
                    id: "lulu-night-shift",
                    animation: legacyStates[.night]!,
                    caption: L10n.text("SLEEPY", zhHans: "困了"),
                    motion: .sleep,
                    weight: 2),
            ]
            pack.variants[.poke, default: []].insert(MascotVariant(
                id: "duo-soft-boop",
                animation: v3(row: 10, fps: 6),
                caption: L10n.text("BOOP!", zhHans: "戳一戳！"),
                motion: .gentle,
                weight: 5,
                playback: .onceHoldLast), at: 0)
            pack.variants[.wake, default: []].insert(MascotVariant(
                id: "duo-morning-stretch",
                animation: v3(row: 11, fps: 4),
                caption: L10n.text("MORNING!", zhHans: "早上好！"),
                motion: .gentle,
                weight: 5,
                playback: .onceHoldLast), at: 0)
        }
        return pack
    }

    /// Installed packs (built-in + directories under customRoot containing manifest.json)
    static func availablePacks() -> [(id: String, name: String)] {
        var result = [(id: builtInID, name: builtInName)]
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: customRoot(), includingPropertiesForKeys: nil)) ?? []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifest = dir.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            let name = (try? JSONSerialization.jsonObject(with: Data(contentsOf: manifest)))
                .flatMap { ($0 as? [String: Any])?["name"] as? String }
            result.append((id: dir.lastPathComponent, name: name ?? dir.lastPathComponent))
        }
        return result
    }

    /// Load by id; invalid/missing falls back to the built-in pack
    static func load(packID: String) -> MascotPack {
        guard packID != builtInID, !packID.isEmpty else { return builtIn() }
        return custom(dirName: packID) ?? builtIn()
    }

    /// Parse a custom pack's manifest.json (state → file name string or frame array)
    static func custom(dirName: String) -> MascotPack? {
        let dir = customRoot().appendingPathComponent(dirName, isDirectory: true)
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let stateMap = root["states"] as? [String: Any] ?? [:]
        let name = root["name"] as? String ?? dirName
        let fps = (root["fps"] as? NSNumber)?.doubleValue ?? 2

        func parseAnimation(_ value: Any, fps: Double) -> MascotAnimation? {
            if let file = value as? String {
                let url = dir.appendingPathComponent(file)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                let ext = url.pathExtension.lowercased()
                return (ext == "gif" || ext == "apng")
                    ? .animatedImage(url)
                    : .frames([url], fps: fps)
            }
            if let list = value as? [String] {
                let urls = list.map { dir.appendingPathComponent($0) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                guard !urls.isEmpty else { return nil }
                return .frames(urls, fps: fps)
            }
            return nil
        }

        var states: [MascotState: MascotAnimation] = [:]
        for (key, value) in stateMap {
            guard let state = MascotState(rawValue: key) else { continue }
            if let animation = parseAnimation(value, fps: fps) {
                states[state] = animation
            }
        }

        var variants: [MascotState: [MascotVariant]] = [:]
        if let variantMap = root["variants"] as? [String: Any] {
            for (key, rawItems) in variantMap {
                guard let state = MascotState(rawValue: key),
                      let items = rawItems as? [[String: Any]]
                else { continue }
                for (index, item) in items.enumerated() {
                    let variantFPS = (item["fps"] as? NSNumber)?.doubleValue ?? fps
                    let source = item["frames"] ?? item["file"]
                    guard let source,
                          let animation = parseAnimation(source, fps: variantFPS)
                    else { continue }
                    let rawMotion = item["motion"] as? String
                    let motion = rawMotion.flatMap(MascotMotionProfile.init(rawValue:))
                        ?? .stateDefault
                    variants[state, default: []].append(MascotVariant(
                        id: item["id"] as? String ?? "\(key)-\(index + 1)",
                        animation: animation,
                        caption: item["caption"] as? String,
                        motion: motion,
                        weight: max(1, (item["weight"] as? NSNumber)?.intValue ?? 1)))
                }
            }
        }
        // At least one idle asset or idle variant is required, otherwise the pack is invalid.
        guard states[.idle] != nil || variants[.idle]?.isEmpty == false else { return nil }

        var captions = MascotPack.defaultCaptions
        if let capMap = root["captions"] as? [String: String] {
            for (key, value) in capMap {
                if let state = MascotState(rawValue: key) { captions[state] = value }
            }
        }
        return MascotPack(
            id: dirName, name: name, states: states,
            captions: captions, variants: variants)
    }
}
