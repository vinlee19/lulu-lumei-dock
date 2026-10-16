import Foundation

/// 吉祥物动画包引用：内置噜噜、随 App 打包的预设形象、用户目录下的自定义包。
/// 持久化的 id 与旧版兼容："built-in" / mascots/ 下的目录名；预设加 "preset:" 前缀。
public enum MascotPackRef: Equatable, Sendable {
    case builtIn
    case preset(String)
    case custom(String)

    public static let builtInID = "built-in"
    public static let presetPrefix = "preset:"

    /// 非法 id（空、含路径分隔符、隐藏目录、..）一律回退内置，避免越出包根目录。
    public init(id: String) {
        if id.isEmpty || id == Self.builtInID {
            self = .builtIn
        } else if id.hasPrefix(Self.presetPrefix) {
            let name = String(id.dropFirst(Self.presetPrefix.count))
            self = Self.isSafeDirectoryName(name) ? .preset(name) : .builtIn
        } else {
            self = Self.isSafeDirectoryName(id) ? .custom(id) : .builtIn
        }
    }

    public var id: String {
        switch self {
        case .builtIn: return Self.builtInID
        case .preset(let name): return Self.presetPrefix + name
        case .custom(let name): return name
        }
    }

    /// 只接受单层目录名：拒绝路径分隔符、隐藏目录（含 . 与 ..）、NUL 与超长名。
    public static func isSafeDirectoryName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128,
              !name.hasPrefix("."),
              !name.contains("/"), !name.contains("\\"), !name.contains("\0")
        else { return false }
        return true
    }
}

/// 界面上传形象的 manifest 读写（Data 进出，无 IO，便于单测）。
/// 只改 name 与 states 里的单文件条目，其余字段（variants / captions / fps…）原样保留。
public enum MascotManifestEditor {
    /// 标记由界面上传生成的包：只有这类包允许在界面里换图、改名、删除。
    public static let originKey = "origin"
    public static let uploadOrigin = "upload"

    /// 界面上可单独换图的状态。idle 是基础形象；其余状态没配图时沿回退链复用。
    public static let editableStates: [MascotState] = [
        .idle, .working, .waiting, .success, .error, .sleeping,
    ]

    public enum EditError: Error, Equatable {
        case malformed
        /// 基础形象（idle）是包有效的前提，只能替换不能清除
        case cannotRemoveBase
    }

    /// 新建上传包：只有一张基础图，所有状态都沿回退链用它。
    public static func makeUploadManifest(name: String, baseFile: String) -> Data {
        let root: [String: Any] = [
            "name": name,
            originKey: uploadOrigin,
            "fps": 2,
            "states": [MascotState.idle.rawValue: baseFile],
        ]
        return encode(root) ?? Data()
    }

    public static func isUpload(_ data: Data) -> Bool {
        (decode(data)?[originKey] as? String) == uploadOrigin
    }

    public static func name(_ data: Data) -> String? {
        decode(data)?["name"] as? String
    }

    /// states 里以单个文件名配置的状态（帧数组等高级写法不在界面编辑范围内，忽略）。
    public static func stateFiles(_ data: Data) -> [MascotState: String] {
        guard let states = decode(data)?["states"] as? [String: Any] else { return [:] }
        var result: [MascotState: String] = [:]
        for (key, value) in states {
            if let state = MascotState(rawValue: key), let file = value as? String {
                result[state] = file
            }
        }
        return result
    }

    /// 设置（file 非 nil）或清除（file 为 nil，回到沿回退链复用）某状态的图片。
    public static func settingState(
        _ state: MascotState, file: String?, in data: Data
    ) throws -> Data {
        guard var root = decode(data) else { throw EditError.malformed }
        var states = root["states"] as? [String: Any] ?? [:]
        if let file {
            states[state.rawValue] = file
        } else {
            guard state != .idle else { throw EditError.cannotRemoveBase }
            states.removeValue(forKey: state.rawValue)
        }
        root["states"] = states
        guard let encoded = encode(root) else { throw EditError.malformed }
        return encoded
    }

    public static func renaming(to name: String, in data: Data) throws -> Data {
        guard var root = decode(data) else { throw EditError.malformed }
        root["name"] = name
        guard let encoded = encode(root) else { throw EditError.malformed }
        return encoded
    }

    /// 某状态实际显示哪个状态的图：自己有图用自己，否则沿回退链找第一个有图的状态。
    public static func effectiveSource(
        for state: MascotState, files: [MascotState: String]
    ) -> MascotState? {
        var current = state
        for _ in 0...MascotState.allCases.count {
            if files[current] != nil { return current }
            let next = current.fallback
            if next == current { return nil }
            current = next
        }
        return nil
    }

    private static func decode(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func encode(_ root: [String: Any]) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}

/// 上传形象的命名规则（纯函数）。
public enum MascotUploadNaming {
    /// 新包目录名 "upload-yyyyMMdd-HHmmss"（UTC），与已有目录冲突时追加 -2、-3…
    public static func directoryName(now: Date, existing: Set<String>) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "upload-" + formatter.string(from: now)
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }

    /// 包内图片文件名带时间戳：换图后 URL 必然变化，渲染层不会命中旧缓存。
    public static func imageFileName(state: MascotState, stamp: Int, ext: String) -> String {
        "\(state.rawValue)-\(stamp).\(ext.lowercased())"
    }

    /// 默认显示名：取源文件名（去扩展名、去首尾空白），过长截断，空则给通用名。
    public static func displayName(fromFileName fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty else { return "我的形象" }
        return String(stem.prefix(24))
    }
}
