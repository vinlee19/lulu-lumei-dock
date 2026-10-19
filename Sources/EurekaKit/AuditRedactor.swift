import Foundation

/// Redaction of audit records before upload (applies to archive output only; the local DB stays
/// raw).
///
/// The goal is to **remove credentials while keeping command structure**, so the archive can still
/// be queried by command / tool: matching fragments become `[REDACTED]` and all other text is kept
/// verbatim. Better to over-mask than to ship a key to the cloud.
public enum AuditRedactor {
    public static let mask = "[REDACTED]"

    public struct Result: Equatable, Sendable {
        public let text: String
        public let redacted: Bool
    }

    /// (pattern, replacement template). The template keeps the prefix via `$1` (e.g.
    /// `Authorization: `) and masks only the value.
    private static let rules: [(NSRegularExpression, String)] = [
        // whole PEM private-key block
        (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#, mask),
        // header values like Authorization / Proxy-Authorization / X-Api-Key
        (#"(?i)((?:proxy-)?authorization\s*[:=]\s*(?:bearer|basic|token)?\s*)[^\s'"]+"#, "$1" + mask),
        (#"(?i)((?:x-)?api[-_]?key\s*[:=]\s*)(?!=)[^\s'"]+"#, "$1" + mask),
        (#"(?i)(\bbearer\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1" + mask),
        // env var assignment: all-caps name containing a sensitive word (export FOO_TOKEN=xxx /
        // DB_PASSWORD="xxx" cmd). Case-sensitive: Python's sort(key=...) / sort_keys= / session_id=
        // are not credentials (these were hit by mistake in practice)
        (#"(\b[A-Z0-9_]*(?:KEY|KEYS|TOKEN|SECRET|PASSWORD|PASSWD|PWD|CREDENTIAL|CREDENTIALS)\s*=\s*)("[^"]*"|'[^']*'|[^\s;&|]+)"#,
         "$1" + mask),
        // command-line flags: --password=x / --token x / --api-key=x
        (#"(?i)(--?(?:password|passwd|pass|token|secret|api-?key|access-?key|secret-?key|auth)[= ]\s*)("[^"]*"|'[^']*'|[^\s]+)"#,
         "$1" + mask),
        // mysql-style -pPASSWORD (attached)
        (#"(\bmysql\S*\s(?:[^|;&]*?\s)?-p)(\S+)"#, "$1" + mask),
        // user:pass@ in URLs
        (#"([a-zA-Z][a-zA-Z0-9+.-]*://[^\s/:@]+:)[^\s/@]+(@)"#, "$1" + mask + "$2"),
        // credentials in URL query parameters
        (##"(?i)([?&](?:access_?token|token|key|api_?key|sig|signature|secret|password|auth|code|X-Amz-Signature|X-Amz-Credential|X-Amz-Security-Token)=)[^&\s'"#]+"##,
         "$1" + mask),
        // common key shapes
        (#"\bsk-ant-[A-Za-z0-9_-]{16,}"#, mask),
        (#"\bsk-[A-Za-z0-9_-]{20,}"#, mask),
        (#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, mask),
        (#"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b"#, mask),
        (#"\bgithub_pat_[A-Za-z0-9_]{40,}\b"#, mask),
        (#"\bglpat-[A-Za-z0-9_-]{20,}\b"#, mask),
        (#"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#, mask),
        (#"\bAIza[0-9A-Za-z_-]{35}\b"#, mask),
        (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, mask),
    ].map { pattern, template in
        // the rules are compile-time constants; a typo should blow up in tests immediately
        (try! NSRegularExpression(pattern: pattern), template)
    }

    public static func redact(detail: String, tool: String) -> Result {
        // write_stdin: raw input sent to an interactive process (possibly a password); mask all of
        // it
        if tool == "write_stdin" {
            return Result(text: "[REDACTED stdin]", redacted: !detail.isEmpty)
        }
        var text = detail
        for (regex, template) in rules {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
        return Result(text: text, redacted: text != detail)
    }
}
