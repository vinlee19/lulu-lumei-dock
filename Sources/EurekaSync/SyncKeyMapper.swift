import Foundation

/// 本地路径 → 对象键的映射与 SigV4 canonical URI 编码。
/// 键布局（host 命名空间防多机冲突）：
/// ```
/// <prefix>/<host>/claude/CLAUDE.md | memories/<rel> | projects/<rel> | skills/<rel>
/// <prefix>/<host>/codex/AGENTS.md | memories/<rel> | sessions/<rel> | skills/<rel>
/// <prefix>/<host>/opencode/skills/<rel> | opencode.db
/// ```
public enum SyncKeyMapper {
    static let namespaceDefaultsKey = "cosDeviceNamespace"

    /// 设备命名空间：gethostname() 小写、[a-z0-9-] 之外替换为 '-'。
    /// 首次算出后固化到 UserDefaults —— 改机器名不会换命名空间导致全量重传。
    public static func deviceNamespace(defaults: UserDefaults = .standard) -> String {
        if let saved = defaults.string(forKey: namespaceDefaultsKey), !saved.isEmpty {
            return saved
        }
        let raw = ProcessInfo.processInfo.hostName
        let cleaned = sanitizeHost(raw)
        defaults.set(cleaned, forKey: namespaceDefaultsKey)
        return cleaned
    }

    /// host 清洗（纯函数，可测）：小写、非 [a-z0-9-] → '-'、折叠连字符、去首尾 '-'
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

    /// 拼对象键：<prefix>/<host>/<category>/<relativePath>（prefix 可为空）
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

    /// SigV4 canonical URI：按 '/' 分段、每段 UTF-8 逐字节 %XX（大写）编码，
    /// 保留 unreserved（A-Za-z0-9 - . _ ~）。请求 URL 与 canonical request
    /// 必须用同一函数产出 → 中文技能名等非 ASCII 键签名恒匹配。
    public static func canonicalURIPath(forKey key: String) -> String {
        "/" + key.split(separator: "/", omittingEmptySubsequences: true)
            .map { SigV4Signer.uriEncode(String($0)) }
            .joined(separator: "/")
    }
}
