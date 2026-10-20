import Foundation

/// Maps a user's own pet folder onto companion states by file name, so a set of images made for
/// another app can be imported without writing a manifest. Pure: the app layer lists the files
/// and copies them.
///
/// Recognised layouts (names are case-insensitive, `_` and spaces count as `-`):
/// - `working.gif` / `working.png` - one file for a state (an animated GIF / APNG plays as is)
/// - `working-1.png`, `working-2.png` - a frame sequence, ordered by the trailing number
/// - `working/01.png`, `working/02.png` - a frame sequence in a subfolder named after the state
/// Each state also answers to a few common aliases (`work`, `busy`, `done`, `sleep`, plus Chinese names; see `aliasNames`).
public enum MascotFolderMapper {
    public struct Result: Equatable, Sendable {
        /// State → files relative to the folder (one file, or frames in play order)
        public var states: [MascotState: [String]]
        /// Images that matched no state (shown to the user, who can bind them by hand)
        public var unmatched: [String]
        /// idle had no file of its own and borrowed this state's art (nil = idle was found)
        public var idleBorrowedFrom: String?
    }

    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "apng", "webp", "heic", "tiff", "tif", "bmp",
    ]
    public static let animatedExtensions: Set<String> = ["gif", "apng"]

    /// Aliases per state; the raw value itself always matches
    public static let aliasNames: [MascotState: [String]] = [
        .idle: ["idle", "default", "normal", "base", "stand", "standing", "平时", "默认", "待机", "空闲"],
        .working: ["working", "work", "busy", "run", "running", "typing", "focus", "工作", "工作中", "忙碌", "专注"],
        .waiting: ["waiting", "wait", "ask", "question", "attention", "alert", "等待", "等你确认", "提问"],
        .success: ["success", "done", "finish", "finished", "complete", "happy", "celebrate", "完成", "成功", "开心"],
        .error: ["error", "fail", "failed", "failure", "sad", "oops", "出错", "失败", "错误", "难过"],
        .sleeping: ["sleeping", "sleep", "zzz", "睡觉", "睡眠"],
        .night: ["night", "sleepy", "tired", "深夜", "困"],
        .relax: ["relax", "rest", "break", "放松", "休息"],
        .poke: ["poke", "click", "tap", "touch", "被戳", "戳"],
        .wake: ["wake", "wakeup", "wake-up", "morning", "醒来"],
    ]

    private static let lookup: [String: MascotState] = {
        var table: [String: MascotState] = [:]
        for (state, names) in aliasNames {
            for name in names { table[normalize(name)] = state }
        }
        return table
    }()

    static func normalize(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// State named by a file stem or folder name; a trailing frame number is ignored
    public static func state(forName name: String) -> MascotState? {
        let normalized = normalize(name)
        if let state = lookup[normalized] { return state }
        let (base, _) = splitFrameIndex(normalized)
        return lookup[base]
    }

    /// "working-02" → ("working", 2); "working" → ("working", nil)
    static func splitFrameIndex(_ name: String) -> (base: String, index: Int?) {
        var digits = ""
        var rest = Substring(name)
        while let last = rest.last, last.isASCII, last.isNumber {
            digits.insert(last, at: digits.startIndex)
            rest = rest.dropLast()
        }
        guard !digits.isEmpty, !rest.isEmpty else { return (name, nil) }
        let base = String(rest).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (base, Int(digits))
    }

    /// `relativePaths` are files under the chosen folder, at most one subfolder deep
    /// ("idle.png", "working/01.png"). Anything else (hidden files, deeper paths, non-images,
    /// manifest.json) is left out silently.
    public static func map(_ relativePaths: [String]) -> Result {
        // state → (frame order key, path)
        var candidates: [MascotState: [(order: Int, path: String)]] = [:]
        var unmatched: [String] = []
        for path in relativePaths.sorted() {
            let parts = path.split(separator: "/").map(String.init)
            guard (1...2).contains(parts.count), !parts.contains(where: { $0.hasPrefix(".") })
            else { continue }
            let file = parts[parts.count - 1]
            let ext = (file as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            let stem = (file as NSString).deletingPathExtension
            let state: MascotState?
            let order: Int
            if parts.count == 2 {
                state = Self.state(forName: parts[0])
                order = splitFrameIndex(normalize(stem)).index ?? Int.max
            } else {
                state = Self.state(forName: stem)
                order = splitFrameIndex(normalize(stem)).index ?? 0
            }
            guard let state else {
                unmatched.append(path)
                continue
            }
            candidates[state, default: []].append((order, path))
        }

        var states: [MascotState: [String]] = [:]
        for (state, items) in candidates {
            let sorted = items.sorted { ($0.order, $0.path) < ($1.order, $1.path) }.map(\.path)
            // An animated file is a whole animation by itself; frames can't be mixed into it
            if let animated = sorted.first(where: {
                animatedExtensions.contains(($0 as NSString).pathExtension.lowercased())
            }) {
                states[state] = [animated]
                unmatched.append(contentsOf: sorted.filter { $0 != animated })
            } else {
                states[state] = sorted
            }
        }

        var borrowed: String?
        if states[.idle] == nil {
            if !unmatched.isEmpty {
                // A lone unrecognised image is most likely the pet's default look
                let base = unmatched.removeFirst()
                states[.idle] = [base]
                borrowed = base
            } else if let source = MascotManifestEditor.editableStates.first(where: {
                states[$0] != nil
            }) {
                states[.idle] = states[source]
                borrowed = source.rawValue
            }
        }
        return Result(states: states, unmatched: unmatched.sorted(), idleBorrowedFrom: borrowed)
    }
}

/// Checks a hand-written manifest before it is imported or listed, so a typo explains itself
/// instead of making the pack silently vanish.
public enum MascotManifestValidator {
    public enum Issue: Equatable, Sendable {
        /// Not a JSON object
        case malformed
        /// No usable idle art (states.idle or variants.idle); the pack can't load
        case noIdle
        case missingFile(state: String, file: String)
        case unknownState(String)

        /// Blocking issues make the pack unusable; the rest only lose that one piece of art
        public var isBlocking: Bool {
            switch self {
            case .malformed, .noIdle: return true
            case .missingFile, .unknownState: return false
            }
        }
    }

    /// `existingFiles` are paths relative to the pack folder
    public static func validate(_ data: Data, existingFiles: Set<String>) -> [Issue] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [.malformed]
        }
        var issues: [Issue] = []
        var usableIdle = false

        func files(in value: Any?) -> [String] {
            if let file = value as? String { return [file] }
            return value as? [String] ?? []
        }

        func check(_ key: String, _ value: Any?) -> Bool {
            let listed = files(in: value)
            var usable = false
            for file in listed {
                if existingFiles.contains(file) {
                    usable = true
                } else {
                    issues.append(.missingFile(state: key, file: file))
                }
            }
            return usable
        }

        for (key, value) in (root["states"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard MascotState(rawValue: key) != nil else {
                issues.append(.unknownState(key))
                continue
            }
            if check(key, value), key == MascotState.idle.rawValue { usableIdle = true }
        }
        for (key, rawItems) in (root["variants"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard MascotState(rawValue: key) != nil else {
                issues.append(.unknownState(key))
                continue
            }
            for item in rawItems as? [[String: Any]] ?? [] {
                if check(key, item["frames"] ?? item["file"]), key == MascotState.idle.rawValue {
                    usableIdle = true
                }
            }
        }
        if !usableIdle { issues.insert(.noIdle, at: 0) }
        return issues
    }
}
