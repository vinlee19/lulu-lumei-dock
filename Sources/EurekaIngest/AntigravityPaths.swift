import Foundation

/// Google Antigravity CLI（`agy`）本地数据路径（`~/.gemini/antigravity-cli`）。
/// 会话是每会话一个 SQLite：`conversations/<uuid>.db`，但正文/token/计划/标题全在
/// 二进制 protobuf blob 里（Google 未公开 schema）——本项目零第三方依赖，无法解 protobuf。
/// 故只做能干净拿到的部分：工作区路径（从 db 字节里裸扫 `file://` URI）、活跃时间（文件 mtime）、
/// 技能（SKILL.md）。env `EUREKA_ANTIGRAVITY_*` 覆盖，便于单测。
public enum AntigravityPaths {
    private static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    /// `~/.gemini`（env `EUREKA_GEMINI_HOME`）
    public static func geminiHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_GEMINI_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".gemini", isDirectory: true)
    }

    /// `~/.gemini/antigravity-cli`（env `EUREKA_ANTIGRAVITY_HOME`）
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ANTIGRAVITY_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return geminiHome(environment: environment)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
    }

    /// 会话根 `~/.gemini/antigravity-cli/conversations`（env `EUREKA_ANTIGRAVITY_CONVERSATIONS`）
    public static func conversationsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ANTIGRAVITY_CONVERSATIONS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return configHome(environment: environment)
            .appendingPathComponent("conversations", isDirectory: true)
    }

    /// 技能根：用户 `~/.gemini/skills` + 内置 `~/.gemini/antigravity-cli/builtin/skills`。
    /// env `EUREKA_ANTIGRAVITY_SKILLS` 覆盖时只用该单一根。
    public static func skillsRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        if let custom = environment["EUREKA_ANTIGRAVITY_SKILLS"], !custom.isEmpty {
            return [URL(fileURLWithPath: custom, isDirectory: true)]
        }
        return [
            geminiHome(environment: environment).appendingPathComponent("skills", isDirectory: true),
            configHome(environment: environment)
                .appendingPathComponent("builtin/skills", isDirectory: true),
        ]
    }

    /// 用户技能根（新建技能写这里）
    public static func userSkillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        skillsRoots(environment: environment)[0]
    }

    // MARK: - 会话 db 裸读（避开 live-WAL 只读打开问题；不依赖 SQLite）

    /// 从会话 db（及其 -wal）字节里裸扫工作区 `file://` URI → 本地路径。
    /// Antigravity 把 workspace_uris 存在 protobuf 字符串里，值以明文 ASCII 落在页数据中。
    public static func cwd(dbURL: URL) -> String? {
        for path in [dbURL.path, dbURL.path + "-wal"] {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            if let uri = findFileURI([UInt8](data)) { return uriToPath(uri) }
        }
        return nil
    }

    /// 会话最近活跃时间 = `.db` 与 `.db-wal` mtime 的较新者
    public static func newestMtime(dbURL: URL) -> Date? {
        var newest: Date?
        for path in [dbURL.path, dbURL.path + "-wal"] {
            guard let m = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
                as? Date else { continue }
            if newest == nil || m > newest! { newest = m }
        }
        return newest
    }

    /// `.db` + `.db-wal` + `.db-shm` 总字节
    public static func sizeBytes(dbURL: URL) -> UInt64 {
        var total: UInt64 = 0
        for path in [dbURL.path, dbURL.path + "-wal", dbURL.path + "-shm"] {
            if let n = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? UInt64 {
                total += n
            }
        }
        return total
    }

    private static let fileNeedle = Array("file:///".utf8)

    /// 在字节里找首个 `file:///…` 字符串。优先用 protobuf 短字符串的单字节长度前缀精确取；
    /// 失败退可打印 ASCII 段（遇控制字符/引号止）。
    static func findFileURI(_ bytes: [UInt8]) -> String? {
        guard let idx = indexOf(fileNeedle, in: bytes) else { return nil }
        // 长度前缀（值 < 128 时为单字节 = 字符串长度，紧邻 'f' 之前）。
        // 仅当整段可打印（无控制字符）才采信——live db 里 URI 可能是被覆盖的碎片，
        // 长度前缀会把后面的二进制（NUL 等）一并框进来，那样的脏串绝不能返回（会让
        // URL.appendingPathComponent 抛不可捕获的 NSException 崩溃）。
        if idx > 0 {
            let len = Int(bytes[idx - 1])
            if len >= fileNeedle.count, len < 128, idx + len <= bytes.count {
                let slice = Array(bytes[idx ..< idx + len])
                if slice.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }),
                   let s = String(bytes: slice, encoding: .utf8), s.hasPrefix("file:///") {
                    return s
                }
            }
        }
        // 兜底：向后收可打印 ASCII（不含引号），遇控制字符即止 → 必为干净串
        var end = idx
        while end < bytes.count, bytes[end] >= 0x20, bytes[end] <= 0x7E, bytes[end] != 0x22 {
            end += 1
        }
        guard end > idx, let s = String(bytes: bytes[idx ..< end], encoding: .utf8),
              s.hasPrefix("file:///") else { return nil }
        return s
    }

    private static func uriToPath(_ uri: String) -> String? {
        guard uri.hasPrefix("file://") else { return nil }
        let raw = String(uri.dropFirst("file://".count))  // "/Users/…"
        let path = raw.removingPercentEncoding ?? raw
        // 百分号解码可能引入控制字符（如 %00）→ 截断到首个控制字符，保证干净路径
        let clean = String(path.unicodeScalars.prefix { $0.value >= 0x20 && $0.value != 0x7F })
        return clean.isEmpty ? nil : clean
    }

    /// 朴素子串查找
    private static func indexOf(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        var i = 0
        while i <= last {
            var j = 0
            while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
            if j == needle.count { return i }
            i += 1
        }
        return nil
    }
}
