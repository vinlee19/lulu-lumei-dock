import Foundation

/// 审计记录上传前的脱敏（只作用于归档输出，本地库保持原样）。
///
/// 目标是**去掉凭证、保留命令结构**，让归档后仍能按命令 / 工具查询：
/// 命中的片段替换为 `[REDACTED]`，其余文字原样保留。宁可多遮一点，也不把密钥送上云。
public enum AuditRedactor {
    public static let mask = "[REDACTED]"

    public struct Result: Equatable, Sendable {
        public let text: String
        public let redacted: Bool
    }

    /// (模式, 替换模板)。模板里用 `$1` 保留前缀（如 `Authorization: `），只遮值。
    private static let rules: [(NSRegularExpression, String)] = [
        // PEM 私钥块整段
        (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#, mask),
        // Authorization / Proxy-Authorization / X-Api-Key 之类的请求头值
        (#"(?i)((?:proxy-)?authorization\s*[:=]\s*(?:bearer|basic|token)?\s*)[^\s'"]+"#, "$1" + mask),
        (#"(?i)((?:x-)?api[-_]?key\s*[:=]\s*)(?!=)[^\s'"]+"#, "$1" + mask),
        (#"(?i)(\bbearer\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1" + mask),
        // 环境变量赋值：全大写变量名里带敏感词（export FOO_TOKEN=xxx / DB_PASSWORD="xxx" cmd）。
        // 区分大小写：Python 的 sort(key=…) / sort_keys= / session_id= 不是凭证（实测误伤过）
        (#"(\b[A-Z0-9_]*(?:KEY|KEYS|TOKEN|SECRET|PASSWORD|PASSWD|PWD|CREDENTIAL|CREDENTIALS)\s*=\s*)("[^"]*"|'[^']*'|[^\s;&|]+)"#,
         "$1" + mask),
        // 命令行参数：--password=x / --token x / --api-key=x
        (#"(?i)(--?(?:password|passwd|pass|token|secret|api-?key|access-?key|secret-?key|auth)[= ]\s*)("[^"]*"|'[^']*'|[^\s]+)"#,
         "$1" + mask),
        // mysql 风格 -pPASSWORD（紧贴）
        (#"(\bmysql\S*\s(?:[^|;&]*?\s)?-p)(\S+)"#, "$1" + mask),
        // URL 里的 user:pass@
        (#"([a-zA-Z][a-zA-Z0-9+.-]*://[^\s/:@]+:)[^\s/@]+(@)"#, "$1" + mask + "$2"),
        // URL 查询参数里的凭证
        (##"(?i)([?&](?:access_?token|token|key|api_?key|sig|signature|secret|password|auth|code|X-Amz-Signature|X-Amz-Credential|X-Amz-Security-Token)=)[^&\s'"#]+"##,
         "$1" + mask),
        // 常见密钥形态
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
        // 规则是编译期常量，写错就该在测试里立刻炸出来
        (try! NSRegularExpression(pattern: pattern), template)
    }

    public static func redact(detail: String, tool: String) -> Result {
        // write_stdin：发给交互进程的原始输入（可能是密码），整段遮掉
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
