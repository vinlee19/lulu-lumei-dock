import Foundation

/// One risk rule: a regex matched against the detail of certain operation kinds; a match flags the
/// given level. Data, not closures → naturally JSON-serializable, so an audit-rules.json override
/// can come later (built-in only for now).
public struct RiskRule: Codable, Sendable, Equatable {
    public var id: String          // "sudo" / "rm-rf" / "curl-pipe-sh"…
    public var title: String       // Localized display title (e.g. "sudo privilege escalation")
    public var level: RiskLevel
    public var kinds: Set<ToolKind> // Domain scoping: command rules scan only command, path rules only edit/read
    public var pattern: String     // Per-line regex (caseInsensitive)

    public init(id: String, title: String, level: RiskLevel, kinds: Set<ToolKind>, pattern: String) {
        self.id = id
        self.title = title
        self.level = level
        self.kinds = kinds
        self.pattern = pattern
    }
}

/// Built-in risk rule engine. Rules are compiled once and cached; returns the first match by
/// descending level, then array order.
public enum RiskRuleEngine {
    /// Built-in rule set (initial release). Order is the priority within a level: more specific
    /// rules come first.
    public static var builtinRules: [RiskRule] { [
        // ── high ─────────────────────────────────────────────
        RiskRule(id: "rm-rf", title: L10n.text("Recursive deletion of an absolute or home path", zhHans: "递归删除绝对/家目录路径"), level: .high, kinds: [.command],
                 pattern: #"\brm\b[^|;&\n]*-{1,2}[a-z]*r[a-z]*\b[^|;&\n]*\s["']?(/|~|\$HOME|\$\{HOME)"#),
        RiskRule(id: "curl-pipe-sh", title: L10n.text("Pipe downloaded content directly to execution", zhHans: "下载内容直接管道执行"), level: .high, kinds: [.command],
                 pattern: #"\b(curl|wget|fetch)\b[^\n]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?|ruby|node|perl)\b"#),
        RiskRule(id: "base64-pipe-sh", title: L10n.text("Pipe decoded base64 content to execution", zhHans: "base64 解码后管道执行"), level: .high, kinds: [.command],
                 pattern: #"\bbase64\b[^\n]*-{1,2}d[^\n]*\|\s*(sh|bash|zsh)\b"#),
        RiskRule(id: "dd-to-device", title: L10n.text("dd writes directly to a block device", zhHans: "dd 直写块设备"), level: .high, kinds: [.command],
                 pattern: #"\bdd\b[^\n]*\bof=/dev/"#),
        RiskRule(id: "mkfs", title: L10n.text("Format a file system", zhHans: "格式化文件系统"), level: .high, kinds: [.command],
                 pattern: #"\bmkfs(\.\w+)?\b"#),
        RiskRule(id: "diskutil-erase", title: L10n.text("diskutil erases or repartitions a disk", zhHans: "diskutil 抹盘/重分区"), level: .high, kinds: [.command],
                 pattern: #"\bdiskutil\s+(erase|reformat|partition)"#),
        RiskRule(id: "chmod-777", title: L10n.text("chmod 777 grants all permissions", zhHans: "chmod 777 开放全权限"), level: .high, kinds: [.command],
                 pattern: #"\bchmod\b[^\n]*\b0?777\b"#),
        RiskRule(id: "read-ssh-key", title: L10n.text("Read an SSH private key", zhHans: "读取 SSH 私钥"), level: .high, kinds: [.read, .search, .command],
                 pattern: #"\b(id_rsa|id_ed25519|id_dsa|id_ecdsa)\b|(^|/)[\w.-]+\.pem\b"#),
        RiskRule(id: "write-ssh", title: L10n.text("Write to the ~/.ssh directory", zhHans: "写入 ~/.ssh 目录"), level: .high, kinds: [.edit, .command],
                 pattern: #"(^|[\s"'/>])\.ssh/"#),
        RiskRule(id: "write-launch-agent", title: L10n.text("Write a startup item", zhHans: "写入开机自启项"), level: .high, kinds: [.edit, .command],
                 pattern: #"Library/Launch(Agents|Daemons)/"#),
        RiskRule(id: "write-etc", title: L10n.text("Write to the system /etc directory", zhHans: "写入系统 /etc 目录"), level: .high, kinds: [.edit, .command],
                 pattern: #"(^|[\s"'>])/etc/"#),
        // ── notice ───────────────────────────────────────────
        RiskRule(id: "rm-rf-rel", title: L10n.text("Recursive deletion (relative path)", zhHans: "递归删除（相对路径）"), level: .notice, kinds: [.command],
                 pattern: #"\brm\b[^|;&\n]*-{1,2}[a-z]*r[a-z]*\b"#),
        RiskRule(id: "read-secret", title: L10n.text("Read a key or credentials file", zhHans: "读取密钥/凭据文件"), level: .notice, kinds: [.read, .search, .command],
                 pattern: #"\.env(\.[a-z]+)?\b|\bcredentials\b|\.aws/credentials\b|\.npmrc\b|\.netrc\b"#),
        RiskRule(id: "git-force-push", title: L10n.text("git force push", zhHans: "git 强制推送"), level: .notice, kinds: [.command],
                 pattern: #"\bgit\s+push\b[^\n]*(-f\b|--force)"#),
        RiskRule(id: "git-reset-hard", title: L10n.text("git hard reset", zhHans: "git 硬重置"), level: .notice, kinds: [.command],
                 pattern: #"\bgit\s+reset\b[^\n]*--hard"#),
        RiskRule(id: "git-clean", title: L10n.text("git clean forced cleanup", zhHans: "git clean 强制清理"), level: .notice, kinds: [.command],
                 pattern: #"\bgit\s+clean\b[^\n]*-[a-z]*f"#),
        RiskRule(id: "sudo", title: L10n.text("sudo privileged execution", zhHans: "sudo 提权执行"), level: .notice, kinds: [.command],
                 pattern: #"\bsudo\b"#),
    ] }

    /// Compile cache: (rule index, compiled regex), stably sorted by descending level (array order
    /// is the secondary key).
    private static let compiled: [(ruleIndex: Int, regex: NSRegularExpression)] = {
        builtinRules
            .enumerated()
            .compactMap { index, rule -> (Int, RiskRule, NSRegularExpression)? in
                guard let regex = try? NSRegularExpression(
                    pattern: rule.pattern, options: [.caseInsensitive])
                else { return nil }
                return (index, rule, regex)
            }
            // Descending level (high first); within a level, original array order
            .sorted { lhs, rhs in
                if lhs.1.level != rhs.1.level { return lhs.1.level > rhs.1.level }
                return lhs.0 < rhs.0
            }
            .map { ($0.0, $0.2) }
    }()

    /// Assess one operation's risk. Returns the first match (highest level, earliest in array
    /// order), or nil if none.
    public static func evaluate(kind: ToolKind, tool: String, detail: String) -> RiskHit? {
        guard !detail.isEmpty else { return nil }
        let range = NSRange(detail.startIndex..., in: detail)
        let rules = builtinRules
        for (ruleIndex, regex) in compiled {
            let rule = rules[ruleIndex]
            guard rule.kinds.contains(kind) else { continue }
            if regex.firstMatch(in: detail, options: [], range: range) != nil {
                return RiskHit(ruleId: rule.id, title: rule.title, level: rule.level)
            }
        }
        return nil
    }
}

/// Alert throttling: the same (session, rule) passes only once per cooldown, so repeated sudo
/// doesn't flood the screen. Pure logic (now is injected), unit-testable.
public struct RiskAlertThrottle: Sendable {
    private let cooldown: TimeInterval
    private let maxEntries: Int
    private var lastFired: [String: Date] = [:]

    public init(cooldown: TimeInterval = 600, maxEntries: Int = 256) {
        self.cooldown = cooldown
        self.maxEntries = maxEntries
    }

    public mutating func shouldAlert(sessionId: String, ruleId: String, now: Date) -> Bool {
        let key = sessionId + "\u{1}" + ruleId
        if let last = lastFired[key], now.timeIntervalSince(last) < cooldown {
            return false
        }
        // Simple growth guard: clear everything past the cap (very few keys, so resetting is cheap)
        if lastFired.count >= maxEntries {
            lastFired.removeAll(keepingCapacity: true)
        }
        lastFired[key] = now
        return true
    }
}
