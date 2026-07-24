import AppKit
import EurekaIngest
import EurekaKit
import Foundation

/// 一个状态对应的动画素材:PNG 帧循环 或 自播放的 GIF/APNG
enum MascotAnimation: Equatable {
    case frames([URL], fps: Double)
    case animatedImage(URL)
    /// v2 精灵图中的任意帧序列。用于同一行拆出多个微行为,也支持 16 向视线。
    case spriteSequence(URL, cells: [MascotSpriteCell], fps: Double)
}

struct MascotSpriteCell: Equatable {
    var row: Int
    var column: Int
}

/// 同一状态下的行为变体。动画、标语和轻微肢体语言可以独立组合。
struct MascotVariant: Equatable {
    var id: String
    var animation: MascotAnimation
    var caption: String?
    var motion: MascotMotionProfile = .stateDefault
    var weight: Int = 1
}

/// 变体级肢体语言。比按状态写死更适合表达眨眼、观察、提醒等微行为。
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

/// 一套吉祥物动画包(内置 or 用户导入)
struct MascotPack {
    var id: String
    var name: String
    var states: [MascotState: MascotAnimation]
    /// 贴纸上的英文艺术字标语(按状态)
    var captions: [MascotState: String] = [:]
    /// 高频状态可拥有多个行为变体；旧动画包不提供时自动包成一个默认变体。
    var variants: [MascotState: [MascotVariant]] = [:]
    /// v2 资源提供的 16 向视线，顺时针从 000°(上)开始。
    var lookDirections: [MascotAnimation] = []

    /// 内置默认英文标语(动画包可在 manifest "captions" 覆盖)
    static let defaultCaptions: [MascotState: String] = [
        .idle: "HELLO", .working: "FOCUS", .waiting: "HEY!", .success: "DONE!",
        .error: "OOPS", .sleeping: "ZZZ", .relax: "RELAX", .night: "SLEEPY",
        .poke: "HEHE~", .wake: "MORNING!",
    ]

    /// 空闲时轮换的姿势集。保留给旧调用方；新逻辑使用 variants(for:)。
    var idlePoses: [MascotAnimation] {
        var result: [MascotAnimation] = []
        for variant in variants(for: .idle) where !result.contains(variant.animation) {
            result.append(variant.animation)
        }
        return result
    }

    /// 返回状态的全部变体。缺失时沿原回退链寻找，最终包成一个默认变体。
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

    /// 取某状态的动画,缺失沿回退链找,最终回到 idle
    func animation(for state: MascotState) -> MascotAnimation? {
        if let direct = states[state] { return direct }
        var current = state
        for _ in 0..<MascotState.allCases.count {
            let next = current.fallback
            if let found = states[next] { return found }
            if next == current { break }  // idle.fallback == idle,到底
            current = next
        }
        return states[.idle]
    }
}

enum MascotPackLoader {
    static let builtInID = "built-in"
    static let builtInName = "噜噜 & 噜妹（内置）"

    /// 用户自定义包根目录:~/Library/Application Support/Eureka/mascots
    static func customRoot() -> URL {
        SpoolPaths.root().appendingPathComponent("mascots", isDirectory: true)
    }

    /// 确保 mascots/ 存在并放一份说明 + 示例 manifest(首次),再在 Finder 打开
    static func revealCustomFolder() {
        let root = customRoot()
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let readme = root.appendingPathComponent("如何制作动画包.txt")
        if !fm.fileExists(atPath: readme.path) {
            try? sampleReadme.write(to: readme, atomically: true, encoding: .utf8)
        }
        let example = root.appendingPathComponent("manifest.example.json")
        if !fm.fileExists(atPath: example.path) {
            try? sampleManifest.write(to: example, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(root)
    }

    private static let sampleReadme = """
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
    """

    private static let sampleManifest = """
    {
      "name": "我的表情包",
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

    /// 内置包：场景贴纸与 v2 双人精灵图共同提供状态变体。
    static func builtIn() -> MascotPack {
        func frames(_ names: [String]) -> MascotAnimation {
            let urls = names.compactMap {
                AppResources.bundle.url(
                    forResource: $0, withExtension: "png", subdirectory: "mascots/lulu")
            }
            return .frames(urls, fps: 2)
        }
        let legacyStates: [MascotState: MascotAnimation] = [
            .idle: frames(["idle-1"]),            // 噜噜托腮沉思
            .working: frames(["working-1", "working-2"]),
            .waiting: frames(["waiting-1"]),      // 噜噜竖手指招呼
            .success: frames(["success-1", "success-2"]),
            .error: frames(["error-1"]),          // 噜妹流汗沮丧
            .sleeping: frames(["sleeping-1", "sleeping-2", "sleeping-3"]),
            .relax: frames(["relax-1", "relax-2", "relax-3"]),
            .night: frames(["night-1", "night-2"]),
            .poke: frames(["poke-1", "poke-2"]),
            .wake: frames(["wake-1"]),
        ]
        var pack = MascotPack(
            id: builtInID, name: builtInName,
            states: legacyStates, captions: MascotPack.defaultCaptions)

        // 即使扩展精灵图缺失，旧场景也有 12 个高频变体，避免退回单一贴纸循环。
        pack.variants = [
            .idle: [
                MascotVariant(id: "lulu-thinking", animation: legacyStates[.idle]!,
                              caption: "THINK", motion: .curious, weight: 3),
                MascotVariant(id: "lumei-lounging", animation: legacyStates[.relax]!,
                              caption: "CHILL", motion: .sway, weight: 2),
                MascotVariant(id: "lumei-soft-nap", animation: legacyStates[.sleeping]!,
                              caption: "NAP", motion: .sleep, weight: 1),
                MascotVariant(id: "lulu-bright-idea", animation: legacyStates[.waiting]!,
                              caption: "IDEA!", motion: .gentle, weight: 2),
            ],
            .working: [
                MascotVariant(id: "lulu-coding", animation: legacyStates[.working]!,
                              caption: "FOCUS", motion: .focus, weight: 4),
                MascotVariant(id: "lulu-deep-focus", animation: legacyStates[.working]!,
                              caption: "FLOW", motion: .still, weight: 3),
                MascotVariant(id: "lulu-reviewing", animation: legacyStates[.success]!,
                              caption: "CHECK", motion: .gentle, weight: 2),
                MascotVariant(id: "lulu-late-shift", animation: legacyStates[.night]!,
                              caption: "STILL ON", motion: .sleep, weight: 1),
            ],
            .waiting: [
                MascotVariant(id: "lulu-calling", animation: legacyStates[.waiting]!,
                              caption: "HEY!", motion: .nudge, weight: 4),
                MascotVariant(id: "lulu-gentle-reminder", animation: legacyStates[.waiting]!,
                              caption: "AHEM", motion: .gentle, weight: 3),
                MascotVariant(id: "lulu-thinking-wait", animation: legacyStates[.idle]!,
                              caption: "HMM?", motion: .curious, weight: 2),
                MascotVariant(id: "lumei-waiting", animation: legacyStates[.relax]!,
                              caption: "YOUR TURN", motion: .nudge, weight: 1),
            ],
        ]

        guard let atlas = AppResources.bundle.url(
            forResource: "lulu-lumei-duo-v2", withExtension: "png",
            subdirectory: "mascots/lulu")
        else { return pack }

        func sprite(row: Int, columns: [Int], fps: Double) -> MascotAnimation {
            .spriteSequence(
                atlas,
                cells: columns.map { MascotSpriteCell(row: row, column: $0) },
                fps: fps)
        }

        // v2 行提供真正的双人动画；旧 3D 场景继续作为交替出现的单人变体。
        pack.variants[.idle]?.insert(contentsOf: [
            MascotVariant(id: "duo-breathing", animation: sprite(
                row: 0, columns: [0, 1, 2, 3, 4, 5], fps: 3),
                caption: nil, motion: .gentle, weight: 5),
            MascotVariant(id: "duo-blink", animation: sprite(
                row: 0, columns: [0, 1, 0, 2, 0, 1], fps: 2.5),
                caption: "HI~", motion: .still, weight: 4),
        ], at: 0)
        pack.variants[.working]?.insert(contentsOf: [
            MascotVariant(id: "duo-focus", animation: sprite(
                row: 7, columns: [0, 1, 2, 3, 4, 5], fps: 4),
                caption: "TOGETHER", motion: .focus, weight: 5),
            MascotVariant(id: "duo-review", animation: sprite(
                row: 8, columns: [0, 1, 2, 3, 4, 5], fps: 3),
                caption: "CHECK", motion: .curious, weight: 4),
        ], at: 0)
        pack.variants[.waiting]?.insert(contentsOf: [
            MascotVariant(id: "duo-awaiting", animation: sprite(
                row: 6, columns: [0, 1, 2, 3, 4, 5], fps: 3),
                caption: "NEED YOU", motion: .nudge, weight: 5),
            MascotVariant(id: "duo-wave", animation: sprite(
                row: 3, columns: [0, 1, 2, 3], fps: 4),
                caption: "OVER HERE!", motion: .gentle, weight: 4),
        ], at: 0)
        pack.variants[.success] = [
            MascotVariant(id: "duo-jump", animation: sprite(
                row: 4, columns: [0, 1, 2, 3, 4], fps: 5),
                caption: "WE DID IT!", motion: .celebrate, weight: 5),
            MascotVariant(id: "duo-happy-wave", animation: sprite(
                row: 3, columns: [0, 1, 2, 3], fps: 4),
                caption: "YAY!", motion: .celebrate, weight: 3),
            MascotVariant(id: "lulu-finished", animation: legacyStates[.success]!,
                          caption: "DONE!", motion: .celebrate, weight: 2),
        ]
        pack.variants[.error] = [
            MascotVariant(id: "duo-soft-fail", animation: sprite(
                row: 5, columns: Array(0..<8), fps: 4),
                caption: "TRY AGAIN", motion: .droop, weight: 5),
            MascotVariant(id: "lumei-oops", animation: legacyStates[.error]!,
                          caption: "OOPS", motion: .droop, weight: 2),
        ]
        pack.variants[.poke] = [
            MascotVariant(id: "duo-startled", animation: sprite(
                row: 4, columns: [0, 1, 2, 3, 4], fps: 7),
                caption: "BOOP!", motion: .celebrate, weight: 3),
            MascotVariant(id: "duo-wave-back", animation: sprite(
                row: 3, columns: [0, 1, 2, 3], fps: 6),
                caption: "HEHE~", motion: .gentle, weight: 2),
        ]
        pack.variants[.wake] = [
            MascotVariant(id: "duo-wake-up", animation: sprite(
                row: 4, columns: [0, 1, 2, 3, 4], fps: 5),
                caption: "AWAKE!", motion: .gentle, weight: 1),
        ]
        pack.lookDirections = (0..<16).map { direction in
            sprite(row: 9 + direction / 8, columns: [direction % 8], fps: 1)
        }
        return pack
    }

    /// 已安装的包(内置 + customRoot 下含 manifest.json 的目录)
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

    /// 按 id 加载;非法/缺失回退内置
    static func load(packID: String) -> MascotPack {
        guard packID != builtInID, !packID.isEmpty else { return builtIn() }
        return custom(dirName: packID) ?? builtIn()
    }

    /// 解析自定义包的 manifest.json(state→ 文件名字符串 或 帧数组)
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
        // idle 素材或 idle 变体至少要有一个，否则包无效。
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
