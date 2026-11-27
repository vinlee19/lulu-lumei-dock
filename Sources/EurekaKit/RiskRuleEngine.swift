import Foundation

/// A rule title in both interface languages. Resolved when shown, never stored resolved, so a rule
/// set built before a language switch still reads right afterwards.
public struct RiskRuleTitle: Equatable, Sendable {
    public var english: String
    public var zhHans: String

    public init(_ english: String, zhHans: String? = nil) {
        self.english = english
        self.zhHans = zhHans ?? english
    }

    public var text: String { L10n.text(english, zhHans: zhHans) }
}

/// One risk rule. Data, not closures, so a rule can be written in a JSON file as well as here.
///
/// What `pattern` is matched against depends on `scope`:
/// - `text`: the whole operation detail
/// - `tool`: the tool name (`server.tool` for MCP)
/// - `segment`: each simple command of a shell command, after `commands` matched its command word
/// - `pipeline`: a command in `commands` whose output reaches one of `pipeInto` (or one of
///   `pipeIntoBare` run without arguments), through a pipe or a substitution
/// - `path`: each path the operation reads or writes (`access`), as written and resolved
public struct RiskRule: Sendable, Equatable {
    public enum Scope: String, Codable, Sendable, CaseIterable {
        case text, tool, segment, pipeline, path
    }

    public enum Access: String, Codable, Sendable, CaseIterable {
        case read, write, any
    }

    public enum Category: String, Codable, Sendable, CaseIterable {
        case credentials, destructive, versionControl, outbound, system, agentConfig, supplyChain,
             network, mcp, custom

        public var label: String {
            switch self {
            case .credentials: return L10n.text("Credentials", zhHans: "凭据")
            case .destructive: return L10n.text("Destructive", zhHans: "破坏性操作")
            case .versionControl: return L10n.text("Version control", zhHans: "版本控制")
            case .outbound: return L10n.text("Outbound and hard to undo", zhHans: "对外与难撤销")
            case .system: return L10n.text("System and persistence", zhHans: "系统与持久化")
            case .agentConfig: return L10n.text("Agent configuration", zhHans: "Agent 配置")
            case .supplyChain: return L10n.text("Supply chain", zhHans: "供应链")
            case .network: return L10n.text("Network", zhHans: "网络")
            case .mcp: return "MCP"
            case .custom: return L10n.text("Custom", zhHans: "自定义")
            }
        }
    }

    public var id: String
    public var title: RiskRuleTitle
    public var level: RiskLevel
    public var category: Category
    /// Operation kinds the rule looks at
    public var kinds: Set<ToolKind>
    public var scope: Scope
    /// Command words (lowercase basenames; a trailing `*` matches a prefix). A wrapper such as
    /// `sudo` matches too. Empty = any command.
    public var commands: [String]
    /// Case-insensitive regex; see the type comment for what it runs against
    public var pattern: String?
    public var pipeInto: [String]
    public var pipeIntoBare: [String]
    /// `path` scope: which of the operation's paths to look at
    public var access: Access
    /// Zones a path operand must be in (empty = any) and must not be in
    public var targets: Set<RiskPathZone>
    public var exceptTargets: Set<RiskPathZone>
    /// A match on the whole detail cancels the hit
    public var exclude: [String]
    public var enabled: Bool

    public init(
        id: String, title: RiskRuleTitle, level: RiskLevel, category: Category,
        kinds: Set<ToolKind>, scope: Scope, commands: [String] = [], pattern: String? = nil,
        pipeInto: [String] = [], pipeIntoBare: [String] = [], access: Access = .any,
        targets: Set<RiskPathZone> = [], exceptTargets: Set<RiskPathZone> = [],
        exclude: [String] = [], enabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.level = level
        self.category = category
        self.kinds = kinds
        self.scope = scope
        self.commands = commands
        self.pattern = pattern
        self.pipeInto = pipeInto
        self.pipeIntoBare = pipeIntoBare
        self.access = access
        self.targets = targets
        self.exceptTargets = exceptTargets
        self.exclude = exclude
        self.enabled = enabled
    }
}

/// The rules in force and the built-in rule list.
public enum RiskRuleEngine {
    private static let shells = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
    private static let interpreters = ["python", "python3", "node", "ruby", "perl", "php", "osascript"]
    private static let recursiveFlag = #"\s-[a-z]*r[a-z]*(\s|$)|\s--recursive(\s|$)"#

    /// Built-in rules. Order is the priority within a level: more specific rules come first.
    public static var builtinRules: [RiskRule] { [
        // ── high ─────────────────────────────────────────────
        RiskRule(
            id: "rm-rf",
            title: RiskRuleTitle("Recursive deletion outside the project", zhHans: "递归删除项目之外的路径"),
            level: .high, category: .destructive, kinds: [.command], scope: .segment,
            commands: ["rm"], pattern: recursiveFlag, targets: [.home, .system]),
        RiskRule(
            id: "curl-pipe-sh",
            title: RiskRuleTitle("Run downloaded content directly", zhHans: "下载内容直接执行"),
            level: .high, category: .supplyChain, kinds: [.command], scope: .pipeline,
            commands: ["curl", "wget", "fetch"], pipeInto: shells, pipeIntoBare: interpreters),
        RiskRule(
            id: "base64-pipe-sh",
            title: RiskRuleTitle("Run decoded base64 content", zhHans: "base64 解码后执行"),
            level: .high, category: .supplyChain, kinds: [.command], scope: .pipeline,
            commands: ["base64"], pattern: #"\s-{1,2}d"#, pipeInto: shells,
            pipeIntoBare: interpreters),
        RiskRule(
            id: "dd-to-device",
            title: RiskRuleTitle("dd writes directly to a block device", zhHans: "dd 直写块设备"),
            level: .high, category: .destructive, kinds: [.command], scope: .segment,
            commands: ["dd"], pattern: #"\bof=/dev/(?!null\b|zero\b|stdout\b|stderr\b|fd/)"#),
        RiskRule(
            id: "mkfs",
            title: RiskRuleTitle("Format a file system", zhHans: "格式化文件系统"),
            level: .high, category: .destructive, kinds: [.command], scope: .segment,
            commands: ["mkfs*", "newfs*"]),
        RiskRule(
            id: "diskutil-erase",
            title: RiskRuleTitle("diskutil erases or repartitions a disk", zhHans: "diskutil 抹盘/重分区"),
            level: .high, category: .destructive, kinds: [.command], scope: .segment,
            commands: ["diskutil"],
            pattern: #"\s(erase\w*|reformat|partition\w*|zeroDisk|randomDisk|secureErase)\b"#),
        RiskRule(
            id: "chmod-777",
            title: RiskRuleTitle("chmod 777 grants all permissions", zhHans: "chmod 777 开放全权限"),
            level: .high, category: .system, kinds: [.command], scope: .segment,
            commands: ["chmod"], pattern: #"\s0?777(\s|$)"#),
        RiskRule(
            id: "read-ssh-key",
            title: RiskRuleTitle("Read an SSH private key", zhHans: "读取 SSH 私钥"),
            level: .high, category: .credentials, kinds: [.read, .search, .command],
            scope: .path, pattern: #"(^|/)id_(rsa|ed25519|dsa|ecdsa)$"#, access: .read),
        RiskRule(
            id: "write-ssh",
            title: RiskRuleTitle("Write to the ~/.ssh directory", zhHans: "写入 ~/.ssh 目录"),
            level: .high, category: .system, kinds: [.edit, .command], scope: .path,
            pattern: #"(^|/)\.ssh/"#, access: .write),
        RiskRule(
            id: "write-launch-agent",
            title: RiskRuleTitle("Write a startup item", zhHans: "写入开机自启项"),
            level: .high, category: .system, kinds: [.edit, .command], scope: .path,
            pattern: #"/Library/Launch(Agents|Daemons)/"#, access: .write),
        RiskRule(
            id: "launchctl-load",
            title: RiskRuleTitle("Load a launchd job", zhHans: "加载 launchd 启动任务"),
            level: .high, category: .system, kinds: [.command], scope: .segment,
            commands: ["launchctl"], pattern: #"\s(load|bootstrap|enable|submit)\b"#),
        RiskRule(
            id: "write-etc",
            title: RiskRuleTitle("Write to the system /etc directory", zhHans: "写入系统 /etc 目录"),
            level: .high, category: .system, kinds: [.edit, .command], scope: .path,
            pattern: #"^(/private)?/etc/"#, access: .write),
        // ── notice ───────────────────────────────────────────
        RiskRule(
            id: "rm-rf-rel",
            title: RiskRuleTitle("Recursive deletion inside the project", zhHans: "递归删除（项目内）"),
            level: .notice, category: .destructive, kinds: [.command], scope: .segment,
            commands: ["rm"], pattern: recursiveFlag, targets: [.cwd, .relative, .unknown]),
        RiskRule(
            id: "read-secret",
            title: RiskRuleTitle("Read a key or credentials file", zhHans: "读取密钥/凭据文件"),
            level: .notice, category: .credentials, kinds: [.read, .search, .command],
            scope: .path,
            pattern: #"(^|/)\.env(\.(?!example$|sample$|template$|dist$)[\w-]+)?$"#
                + #"|/\.aws/credentials$|(^|/)\.(netrc|npmrc|pypirc)$"#,
            access: .read),
        RiskRule(
            id: "read-pem",
            title: RiskRuleTitle("Read a PEM file (certificate or key)", zhHans: "读取 PEM 文件（证书或密钥）"),
            level: .notice, category: .credentials, kinds: [.read, .search, .command],
            scope: .path, pattern: #"\.pem$"#, access: .read),
        RiskRule(
            id: "git-force-push",
            title: RiskRuleTitle("git force push", zhHans: "git 强制推送"),
            level: .notice, category: .versionControl, kinds: [.command], scope: .segment,
            commands: ["git"], pattern: #"\spush\b.*\s(-f|--force\S*)(\s|$)"#),
        RiskRule(
            id: "git-reset-hard",
            title: RiskRuleTitle("git hard reset", zhHans: "git 硬重置"),
            level: .notice, category: .versionControl, kinds: [.command], scope: .segment,
            commands: ["git"], pattern: #"\sreset\b.*\s--hard\b"#),
        RiskRule(
            id: "git-clean",
            title: RiskRuleTitle("git clean forced cleanup", zhHans: "git clean 强制清理"),
            level: .notice, category: .versionControl, kinds: [.command], scope: .segment,
            commands: ["git"], pattern: #"\sclean\b.*\s-[a-z]*f"#),
        RiskRule(
            id: "sudo",
            title: RiskRuleTitle("sudo privileged execution", zhHans: "sudo 提权执行"),
            level: .notice, category: .system, kinds: [.command], scope: .segment,
            commands: ["sudo"]),
    ] }

    /// Bumped whenever a built-in rule's matching changes, so stored history is evaluated again
    /// even if the rule list hashes the same
    public static let builtinVersion = 2

    private static let lock = NSLock()
    private static var installed: RiskRuleSet?

    /// The rule set every evaluation uses. Built-in rules until something else is installed.
    public static var current: RiskRuleSet {
        lock.lock()
        defer { lock.unlock() }
        if let installed { return installed }
        let builtin = RiskRuleSet(rules: builtinRules)
        installed = builtin
        return builtin
    }

    public static func install(_ ruleSet: RiskRuleSet) {
        lock.lock()
        installed = ruleSet
        lock.unlock()
    }

    /// Identifies the rules history was last evaluated with
    public static var fingerprint: String {
        "\(builtinVersion):\(current.fingerprint)"
    }

    /// Display title of a rule id stored with an audit record; nil for a rule that no longer exists
    public static func title(forRule id: String) -> String? {
        current.rule(id: id)?.title.text
    }

    /// Assess one operation's risk. Returns the first match (highest level, earliest in rule
    /// order), or nil if none.
    public static func evaluate(
        kind: ToolKind, tool: String, detail: String, cwd: String? = nil,
        home: String = NSHomeDirectory()
    ) -> RiskHit? {
        current.evaluate(kind: kind, tool: tool, detail: detail, cwd: cwd, home: home)
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
