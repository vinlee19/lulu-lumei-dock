import Foundation

/// Local data paths of the Google Antigravity CLI (`agy`) (`~/.gemini/antigravity-cli`). Each
/// session is its own SQLite file, `conversations/<uuid>.db`, but bodies/tokens/plans/titles all
/// sit in binary protobuf blobs (schema not published by Google), and this project has zero
/// third-party deps, so it cannot decode protobuf. So only what can be read cleanly is used:
/// workspace path (raw scan of `file://` URIs in the db bytes), activity time (file mtime), skills
/// (SKILL.md). Overridable via env `EUREKA_ANTIGRAVITY_*` for unit tests.
public enum AntigravityPaths {
    private static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    /// `~/.gemini` (env `EUREKA_GEMINI_HOME`)
    public static func geminiHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_GEMINI_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".gemini", isDirectory: true)
    }

    /// `~/.gemini/antigravity-cli` (env `EUREKA_ANTIGRAVITY_HOME`)
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ANTIGRAVITY_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return geminiHome(environment: environment)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
    }

    /// Session root `~/.gemini/antigravity-cli/conversations` (env
    /// `EUREKA_ANTIGRAVITY_CONVERSATIONS`)
    public static func conversationsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ANTIGRAVITY_CONVERSATIONS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return configHome(environment: environment)
            .appendingPathComponent("conversations", isDirectory: true)
    }

    /// Skill roots: user `~/.gemini/antigravity/skills` + built-in
    /// `~/.gemini/antigravity-cli/builtin/skills`. When env `EUREKA_ANTIGRAVITY_SKILLS` overrides,
    /// only that single root is used.
    ///
    /// Warning: the user root is **not** `~/.gemini/skills` -- that one is Gemini's. They are
    /// separate directories (verified: different inodes, and a same-named `SKILL.md` is a separate
    /// copy in each). It once pointed there, so a "new Antigravity skill" was written into Gemini's
    /// directory and, after a refresh, indexed as a gemini source -- renamed right after creation.
    public static func skillsRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        if let custom = environment["EUREKA_ANTIGRAVITY_SKILLS"], !custom.isEmpty {
            return [URL(fileURLWithPath: custom, isDirectory: true)]
        }
        return [
            userSkillsRoot(environment: environment),
            configHome(environment: environment)
                .appendingPathComponent("builtin/skills", isDirectory: true),
        ]
    }

    /// User skill root `~/.gemini/antigravity/skills` (new skills are written here). When env
    /// `EUREKA_ANTIGRAVITY_SKILLS` overrides, that single root is used, consistent with
    /// `skillsRoots()`.
    public static func userSkillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ANTIGRAVITY_SKILLS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return geminiHome(environment: environment)
            .appendingPathComponent("antigravity/skills", isDirectory: true)
    }

    // MARK: - Raw read of the session db (avoids the live-WAL read-only open problem; no SQLite dependency)

    /// Raw-scans the session db (and its -wal) bytes for the workspace `file://` URI → local path.
    /// Antigravity stores workspace_uris in protobuf strings, whose values land in page data as
    /// plain ASCII.
    /// Read in 1 MB chunks that overlap by 4 KB (a URI never straddles a boundary unseen), stopping
    /// at the first hit: the whole file used to be loaded and copied into a byte array.
    public static func cwd(dbURL: URL) -> String? {
        for path in [dbURL.path, dbURL.path + "-wal"] {
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            var carry: [UInt8] = []
            while let piece = try? handle.read(upToCount: 1 << 20), !piece.isEmpty {
                let chunk = carry + [UInt8](piece)
                if let uri = findFileURI(chunk) { return uriToPath(uri) }
                carry = Array(chunk.suffix(4096))
            }
        }
        return nil
    }

    /// Session last-active time = the newer of the `.db` and `.db-wal` mtimes
    public static func newestMtime(dbURL: URL) -> Date? {
        var newest: Date?
        for path in [dbURL.path, dbURL.path + "-wal"] {
            guard let m = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
                as? Date else { continue }
            if newest == nil || m > newest! { newest = m }
        }
        return newest
    }

    /// Total bytes of `.db` + `.db-wal` + `.db-shm`
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

    /// Finds the first `file:///…` string in the bytes. Prefers the exact single-byte length prefix
    /// of a short protobuf string; falls back to a printable ASCII run (stopping at a control
    /// character/quote).
    static func findFileURI(_ bytes: [UInt8]) -> String? {
        guard let idx = indexOf(fileNeedle, in: bytes) else { return nil }
        // Length prefix (for values < 128 it is a single byte = the string length, right before the
        // 'f'). Trusted only if the whole run is printable (no control chars) -- in a live db the
        // URI may be an overwritten fragment, and the length prefix would frame trailing binary
        // (NUL etc.) along with it; such a dirty string must never be returned (it makes
        // URL.appendingPathComponent throw an uncatchable NSException and crash).
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
        // Fallback: collect printable ASCII forward (excluding quotes), stopping at a control char
        // → always a clean string
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
        // Percent-decoding may introduce control chars (e.g. %00) → truncate at the first control
        // char to keep the path clean
        let clean = String(path.unicodeScalars.prefix { $0.value >= 0x20 && $0.value != 0x7F })
        return clean.isEmpty ? nil : clean
    }

    /// Naive substring search
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
