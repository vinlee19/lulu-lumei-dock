import AppKit
import EurekaIngest
import EurekaKit
import Foundation

/// 一个状态对应的动画素材:PNG 帧循环 或 自播放的 GIF/APNG
enum MascotAnimation: Equatable {
    case frames([URL], fps: Double)
    case animatedImage(URL)
}

/// 一套吉祥物动画包(内置 or 用户导入)
struct MascotPack {
    var id: String
    var name: String
    var states: [MascotState: MascotAnimation]
    /// 贴纸上的英文艺术字标语(按状态)
    var captions: [MascotState: String] = [:]

    /// 内置默认英文标语(动画包可在 manifest "captions" 覆盖)
    static let defaultCaptions: [MascotState: String] = [
        .idle: "HELLO", .working: "FOCUS", .waiting: "HEY!", .success: "DONE!",
        .error: "OOPS", .sleeping: "ZZZ", .relax: "RELAX", .night: "SLEEPY",
        .poke: "HEHE~",
    ]

    /// 空闲时轮换的姿势集(idle + relax,让噜噜/噜妹换着露脸,不单调)
    var idlePoses: [MascotAnimation] {
        var result: [MascotAnimation] = []
        if let idle = animation(for: .idle) { result.append(idle) }
        if let relax = states[.relax], !result.contains(relax) { result.append(relax) }
        return result
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
    4. 状态全集:idle / working / waiting / success / error / sleeping / relax / night
       - idle 必填;其余缺失会自动回退到 idle。
    5. 回 Eureka 设置 → 桌面伙伴 → 动画包,选你的包即可(新建后可能需重开设置面板刷新列表)。

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
        "night": ["night-1.png", "night-2.png"]
      }
    }
    """

    /// 内置包:从应用资源 bundle 的 mascots/lulu 读 PNG 帧(state→2 帧循环)
    static func builtIn() -> MascotPack {
        func frames(_ names: [String]) -> MascotAnimation {
            let urls = names.compactMap {
                AppResources.bundle.url(
                    forResource: $0, withExtension: "png", subdirectory: "mascots/lulu")
            }
            return .frames(urls, fps: 2)
        }
        return MascotPack(id: builtInID, name: builtInName, states: [
            .idle: frames(["idle-1"]),            // 噜噜托腮沉思
            .working: frames(["working-1", "working-2"]),
            .waiting: frames(["waiting-1"]),      // 噜噜竖手指招呼
            .success: frames(["success-1", "success-2"]),
            .error: frames(["error-1"]),          // 噜妹流汗沮丧
            .sleeping: frames(["sleeping-1", "sleeping-2"]),
            .relax: frames(["relax-1", "relax-2"]),
            .night: frames(["night-1", "night-2"]),
        ], captions: MascotPack.defaultCaptions)
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
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stateMap = root["states"] as? [String: Any]
        else { return nil }
        let name = root["name"] as? String ?? dirName
        let fps = (root["fps"] as? NSNumber)?.doubleValue ?? 2

        var states: [MascotState: MascotAnimation] = [:]
        for (key, value) in stateMap {
            guard let state = MascotState(rawValue: key) else { continue }
            if let file = value as? String {
                let url = dir.appendingPathComponent(file)
                let ext = url.pathExtension.lowercased()
                states[state] = (ext == "gif" || ext == "apng")
                    ? .animatedImage(url)
                    : .frames([url], fps: fps)  // 单 png/jpg 当静帧
            } else if let list = value as? [String] {
                states[state] = .frames(list.map { dir.appendingPathComponent($0) }, fps: fps)
            }
        }
        // idle 缺失 → 包无效
        guard states[.idle] != nil else { return nil }

        var captions = MascotPack.defaultCaptions
        if let capMap = root["captions"] as? [String: String] {
            for (key, value) in capMap {
                if let state = MascotState(rawValue: key) { captions[state] = value }
            }
        }
        return MascotPack(id: dirName, name: name, states: states, captions: captions)
    }
}
