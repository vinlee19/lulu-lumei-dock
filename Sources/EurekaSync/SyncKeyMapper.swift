import Foundation

/// Maps local paths → object keys, and does SigV4 canonical URI encoding.
/// Key layout (the host namespace prevents collisions between machines):
/// ```
/// <prefix>/<host>/claude/CLAUDE.md | memories/<rel> | projects/<rel> | skills/<rel>
/// <prefix>/<host>/codex/AGENTS.md | memories/<rel> | sessions/<rel> | skills/<rel>
/// <prefix>/<host>/opencode/skills/<rel> | opencode.db
/// ```
public enum SyncKeyMapper {
    static let namespaceDefaultsKey = "cosDeviceNamespace"

    /// Device namespace: gethostname() lowercased, anything outside [a-z0-9-] replaced with '-'.
    /// Pinned in UserDefaults once first computed, so renaming the machine doesn't switch
    /// namespaces and trigger a full re-upload.
    public static func deviceNamespace(defaults: UserDefaults = .standard) -> String {
        if let saved = defaults.string(forKey: namespaceDefaultsKey), !saved.isEmpty {
            return saved
        }
        let raw = ProcessInfo.processInfo.hostName
        let cleaned = sanitizeHost(raw)
        defaults.set(cleaned, forKey: namespaceDefaultsKey)
        return cleaned
    }

    /// Host sanitizing (pure, testable): lowercase, non-[a-z0-9-] → '-', collapse hyphens, trim
    /// leading/trailing '-'
    public static func sanitizeHost(_ raw: String) -> String {
        var cleaned = String(raw.lowercased().map { char -> Character in
            (char.isLetter && char.isASCII) || (char.isNumber && char.isASCII) || char == "-"
                ? char : "-"
        })
        while cleaned.contains("--") {
            cleaned = cleaned.replacingOccurrences(of: "--", with: "-")
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "unknown-host" : cleaned
    }

    /// Builds the object key: <prefix>/<host>/<category>/<relativePath> (prefix may be empty)
    public static func key(
        prefix: String, host: String, category: String, relativePath: String
    ) -> String {
        let trimmedPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var parts: [String] = []
        if !trimmedPrefix.isEmpty { parts.append(trimmedPrefix) }
        parts.append(host)
        parts.append(category)
        let rel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !rel.isEmpty { parts.append(rel) }
        return parts.joined(separator: "/")
    }

    /// SigV4 canonical URI: split on '/', percent-encode each segment's UTF-8 bytes as %XX
    /// (uppercase),
    /// keeping unreserved (A-Za-z0-9 - . _ ~). The request URL and the canonical request
    /// must be produced by the same function → keys with non-ASCII text such as Chinese skill names
    /// always sign matching.
    public static func canonicalURIPath(forKey key: String) -> String {
        "/" + key.split(separator: "/", omittingEmptySubsequences: true)
            .map { SigV4Signer.uriEncode(String($0)) }
            .joined(separator: "/")
    }
}
