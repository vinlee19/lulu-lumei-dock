import Foundation

/// 一条风险规则：对某几类操作的 detail 正则匹配，命中则标记对应等级。
/// 数据化（非闭包）→ 天然可 JSON 序列化，后续可走 audit-rules.json override（本期只内置）。
public struct RiskRule: Codable, Sendable, Equatable {
    public var id: String          // "sudo" / "rm-rf" / "curl-pipe-sh"…
    public var title: String       // 中文标题（「sudo 提权执行」）
    public var level: RiskLevel
    public var kinds: Set<ToolKind> // 域限定：命令规则只扫 command，路径规则只扫 edit/read
    public var pattern: String     // 逐行正则（caseInsensitive）

    public init(id: String, title: String, level: RiskLevel, kinds: Set<ToolKind>, pattern: String) {
        self.id = id
        self.title = title
        self.level = level
        self.kinds = kinds
        self.pattern = pattern
    }
}

/// 内置风险规则引擎。规则编译一次缓存，按 level 降序、数组序返回首个命中。
public enum RiskRuleEngine {
    /// 内置规则集（首发）。顺序即同级优先级：更具体的规则排在前。
    public static let builtinRules: [RiskRule] = [
        // ── high ─────────────────────────────────────────────
        RiskRule(id: "rm-rf", title: "递归删除绝对/家目录路径", level: .high, kinds: [.command],
                 pattern: #"\brm\b[^|;&\n]*-{1,2}[a-z]*r[a-z]*\b[^|;&\n]*\s["']?(/|~|\$HOME|\$\{HOME)"#),
        RiskRule(id: "curl-pipe-sh", title: "下载内容直接管道执行", level: .high, kinds: [.command],
                 pattern: #"\b(curl|wget|fetch)\b[^\n]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?|ruby|node|perl)\b"#),
        RiskRule(id: "base64-pipe-sh", title: "base64 解码后管道执行", level: .high, kinds: [.command],
                 pattern: #"\bbase64\b[^\n]*-{1,2}d[^\n]*\|\s*(sh|bash|zsh)\b"#),
        RiskRule(id: "dd-to-device", title: "dd 直写块设备", level: .high, kinds: [.command],
                 pattern: #"\bdd\b[^\n]*\bof=/dev/"#),
        RiskRule(id: "mkfs", title: "格式化文件系统", level: .high, kinds: [.command],
                 pattern: #"\bmkfs(\.\w+)?\b"#),
        RiskRule(id: "diskutil-erase", title: "diskutil 抹盘/重分区", level: .high, kinds: [.command],
                 pattern: #"\bdiskutil\s+(erase|reformat|partition)"#),
        RiskRule(id: "chmod-777", title: "chmod 777 开放全权限", level: .high, kinds: [.command],
                 pattern: #"\bchmod\b[^\n]*\b0?777\b"#),
        RiskRule(id: "read-ssh-key", title: "读取 SSH 私钥", level: .high, kinds: [.read, .search, .command],
                 pattern: #"\b(id_rsa|id_ed25519|id_dsa|id_ecdsa)\b|(^|/)[\w.-]+\.pem\b"#),
        RiskRule(id: "write-ssh", title: "写入 ~/.ssh 目录", level: .high, kinds: [.edit, .command],
                 pattern: #"(^|[\s"'/>])\.ssh/"#),
        RiskRule(id: "write-launch-agent", title: "写入开机自启项", level: .high, kinds: [.edit, .command],
                 pattern: #"Library/Launch(Agents|Daemons)/"#),
        RiskRule(id: "write-etc", title: "写入系统 /etc 目录", level: .high, kinds: [.edit, .command],
                 pattern: #"(^|[\s"'>])/etc/"#),
        // ── notice ───────────────────────────────────────────
        RiskRule(id: "rm-rf-rel", title: "递归删除（相对路径）", level: .notice, kinds: [.command],
                 pattern: #"\brm\b[^|;&\n]*-{1,2}[a-z]*r[a-z]*\b"#),
        RiskRule(id: "read-secret", title: "读取密钥/凭据文件", level: .notice, kinds: [.read, .search, .command],
                 pattern: #"\.env(\.[a-z]+)?\b|\bcredentials\b|\.aws/credentials\b|\.npmrc\b|\.netrc\b"#),
        RiskRule(id: "git-force-push", title: "git 强制推送", level: .notice, kinds: [.command],
                 pattern: #"\bgit\s+push\b[^\n]*(-f\b|--force)"#),
        RiskRule(id: "git-reset-hard", title: "git 硬重置", level: .notice, kinds: [.command],
                 pattern: #"\bgit\s+reset\b[^\n]*--hard"#),
        RiskRule(id: "git-clean", title: "git clean 强制清理", level: .notice, kinds: [.command],
                 pattern: #"\bgit\s+clean\b[^\n]*-[a-z]*f"#),
        RiskRule(id: "sudo", title: "sudo 提权执行", level: .notice, kinds: [.command],
                 pattern: #"\bsudo\b"#),
    ]

    /// 编译缓存：(规则, 编译好的正则)，按 level 降序稳定排序（数组序为二级键）。
    private static let compiled: [(rule: RiskRule, regex: NSRegularExpression)] = {
        builtinRules
            .enumerated()
            .compactMap { index, rule -> (Int, RiskRule, NSRegularExpression)? in
                guard let regex = try? NSRegularExpression(
                    pattern: rule.pattern, options: [.caseInsensitive])
                else { return nil }
                return (index, rule, regex)
            }
            // level 降序（high 先），同级按原数组序
            .sorted { lhs, rhs in
                if lhs.1.level != rhs.1.level { return lhs.1.level > rhs.1.level }
                return lhs.0 < rhs.0
            }
            .map { ($0.1, $0.2) }
    }()

    /// 对一次操作求风险。返回首个（最高级、数组序最前）命中，无命中返回 nil。
    public static func evaluate(kind: ToolKind, tool: String, detail: String) -> RiskHit? {
        guard !detail.isEmpty else { return nil }
        let range = NSRange(detail.startIndex..., in: detail)
        for (rule, regex) in compiled where rule.kinds.contains(kind) {
            if regex.firstMatch(in: detail, options: [], range: range) != nil {
                return RiskHit(ruleId: rule.id, title: rule.title, level: rule.level)
            }
        }
        return nil
    }
}

/// 告警节流：同一 (会话, 规则) 在冷却期内只放行一次，避免反复 sudo 刷屏。
/// 纯逻辑（now 外部注入），可单测。
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
        // 简单防膨胀：超上限清空（键极少，重置成本可忽略）
        if lastFired.count >= maxEntries {
            lastFired.removeAll(keepingCapacity: true)
        }
        lastFired[key] = now
        return true
    }
}
